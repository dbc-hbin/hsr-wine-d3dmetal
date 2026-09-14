#!/usr/bin/env node

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

function matchingBrace(source, open) {
  let quote = "";
  let lineComment = false;
  let blockComment = false;
  let depth = 0;

  for (let index = open; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];

    if (lineComment) {
      if (current === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (current === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (current === "\\") {
        index += 1;
      } else if (current === quote) {
        quote = "";
      }
      continue;
    }
    if (current === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (current === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (current === '"' || current === "'") {
      quote = current;
      continue;
    }
    if (current === "{") depth += 1;
    if (current === "}") {
      depth -= 1;
      if (!depth) return index;
    }
  }

  throw new Error("unterminated production body");
}

function extractFunction(source, name) {
  const expression = new RegExp(
    `(?:^|\\n)(?:static\\s+)?[^;{}\\n]*\\b${name}\\s*\\([^;{}]*\\)\\s*\\{`,
    "m",
  );
  const match = expression.exec(source);
  if (!match) throw new Error(`missing production function ${name}`);
  const start = match.index + (match[0].startsWith("\n") ? 1 : 0);
  const open = source.indexOf("{", start);
  return source.slice(start, matchingBrace(source, open) + 1);
}

function extractMethod(source, selector) {
  const selectorAt = source.indexOf(selector);
  if (selectorAt < 0) throw new Error(`missing production method ${selector}`);
  const start = source.lastIndexOf("\n", selectorAt) + 1;
  const open = source.indexOf("{", selectorAt);
  if (open < 0) throw new Error(`missing production method body ${selector}`);
  return source.slice(start, matchingBrace(source, open) + 1);
}


function extractRawDelivery(source) {
  const method = extractMethod(source, "handleMouseMove:");
  const rawAccumulator = /\braw\w*DeltaX\s*\+=\s*\[anEvent deltaX\]\s*;/g;
  let rawStatement;
  let start = -1;

  while ((rawStatement = rawAccumulator.exec(method))) start = rawStatement.index;
  if (start < 0) throw new Error("missing production physical RawInput transformation");

  const delivery = /if\s*\(\s*event->type\s*==\s*MOUSE_MOVED_ABSOLUTE[\s\S]*?\)\s*\{/g;
  const conditional = delivery.exec(method.slice(start));
  if (!conditional) throw new Error("missing production RawInput delivery condition");

  const open = start + conditional.index + conditional[0].length - 1;
  return method.slice(start, matchingBrace(method, open) + 1);
}

function run(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    cwd: root,
    encoding: "utf8",
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${arguments_.join(" ")} failed:\n${result.stdout}${result.stderr}`);
  }
  return result;
}

const queueSource = readFileSync(join(root, "dlls/winemac.drv/cocoa_event.m"), "utf8");
const mouseSource = readFileSync(join(root, "dlls/winemac.drv/mouse.c"), "utf8");
const serverSource = readFileSync(join(root, "server/queue.c"), "utf8");

const queueMethod = extractMethod(queueSource, "postEventObject:");
const rawDelivery = extractRawDelivery(readFileSync(join(root, "dlls/winemac.drv/cocoa_app.m"), "utf8"));
const sendMouseInput = extractFunction(mouseSource, "send_mouse_input");
const mouseMoved = extractFunction(mouseSource, "macdrv_mouse_moved");
const mouseButton = extractFunction(mouseSource, "macdrv_mouse_button");
const mouseScroll = extractFunction(mouseSource, "macdrv_mouse_scroll");
const ownerWindowUpdate = extractFunction(serverSource, "update_desktop_cursor_window");

const sharedPrelude = String.raw`#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *HWND;
typedef unsigned int UINT;
typedef unsigned int DWORD;
typedef unsigned short WORD;
typedef intptr_t LPARAM;
typedef uintptr_t ULONG_PTR;
typedef unsigned int user_handle_t;
typedef unsigned int lparam_t;

#define TRUE 1
#define FALSE 0
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#define MOUSE_MOVED_RELATIVE 1
#define MOUSE_MOVED_ABSOLUTE 2
#define MOUSE_BUTTON 3
#define MOUSE_SCROLL 4
#define MOUSEEVENTF_MOVE 0x0001
#define MOUSEEVENTF_LEFTDOWN 0x0002
#define MOUSEEVENTF_LEFTUP 0x0004
#define MOUSEEVENTF_RIGHTDOWN 0x0008
#define MOUSEEVENTF_RIGHTUP 0x0010
#define MOUSEEVENTF_MIDDLEDOWN 0x0020
#define MOUSEEVENTF_MIDDLEUP 0x0040
#define MOUSEEVENTF_XDOWN 0x0080
#define MOUSEEVENTF_XUP 0x0100
#define MOUSEEVENTF_WHEEL 0x0800
#define MOUSEEVENTF_HWHEEL 0x1000
#define MOUSEEVENTF_ABSOLUTE 0x8000
#define MOUSEEVENTF_MOVE_NOCOALESCE 0x2000
#define INPUT_MOUSE 0
#define SEND_HWMSG_RAWINPUT 0x0001
#define WM_WINE_SETCURSOR 0x0401
#define TRACE(...) do { } while (0)

struct raw_mouse_data { int x; int y; };
struct raw_mouse { UINT count; struct raw_mouse_data data[1]; };
typedef struct
{
    int type;
    struct
    {
        int dx;
        int dy;
        DWORD mouseData;
        DWORD dwFlags;
        DWORD time;
        ULONG_PTR dwExtraInfo;
    } mi;
} INPUT;

typedef struct macdrv_event
{
    int type;
    void *window;
    int deliver;
    union
    {
        struct
        {
            int x;
            int y;
            bool drag;
            bool noncoalescible;
            int raw_x;
            int raw_y;
            unsigned long time_ms;
        } mouse_moved;
        struct
        {
            int button;
            bool pressed;
            int x;
            int y;
            unsigned long time_ms;
        } mouse_button;
        struct
        {
            int x_scroll;
            int y_scroll;
            int x;
            int y;
            unsigned long time_ms;
        } mouse_scroll;
    };
} macdrv_event;

static void require_true(BOOL condition, const char *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

@interface ProbeEvent : NSObject
{
@public
    double delta_x;
    double delta_y;
    NSTimeInterval event_time;
}
- (double)deltaX;
- (double)deltaY;
- (NSTimeInterval)timestamp;
@end

@implementation ProbeEvent
- (double)deltaX { return delta_x; }
- (double)deltaY { return delta_y; }
- (NSTimeInterval)timestamp { return event_time; }
@end

@interface ProbeQueue : NSObject
{
@public
    macdrv_event delivered[16];
    unsigned int delivered_count;
}
- (void)postEvent:(macdrv_event *)event;
- (void)clear;
@end

@implementation ProbeQueue
- (void)postEvent:(macdrv_event *)event
{
    require_true(delivered_count < 16, "raw delivery probe overflow");
    delivered[delivered_count++] = *event;
}
- (void)clear { delivered_count = 0; }
@end

@interface WineWindow : NSObject
{
@public
    ProbeQueue *queue;
}
@property(nonatomic, retain) ProbeQueue *queue;
@end

@implementation WineWindow
@synthesize queue;
@end

@interface WineApplicationController : NSObject
{
@public
    double rawMouseMoveDeltaX;
    double rawMouseMoveDeltaY;
}
- (unsigned long)ticksForEventTime:(NSTimeInterval)time;
- (void)applyProductionRawDelivery:(ProbeEvent *)anEvent
                              event:(macdrv_event *)event
                              scale:(double)scale
                       targetWindow:(WineWindow *)targetWindow
                               drag:(BOOL)drag;
@end

@implementation WineApplicationController
- (unsigned long)ticksForEventTime:(NSTimeInterval)time { return (unsigned long)time; }
- (void)applyProductionRawDelivery:(ProbeEvent *)anEvent
                              event:(macdrv_event *)event
                              scale:(double)scale
                       targetWindow:(WineWindow *)targetWindow
                               drag:(BOOL)drag
{
    BOOL noncoalescible = FALSE;
`;

const sharedMiddle = String.raw`
}
@end

@interface MacDrvEvent : NSObject
{
@public
    macdrv_event *event;
}
@end
@implementation MacDrvEvent
@end

@interface WineEventQueue : NSObject
{
@public
    NSMutableArray *events;
    NSLock *eventsLock;
    NSUInteger cleanupIndex;
}
- (void)postEventObject:(MacDrvEvent *)event;
- (void)signalEventAvailable;
@end

@implementation WineEventQueue
- (void)signalEventAvailable { }
`;

const sharedPostQueue = String.raw`
@end

static macdrv_event queued_events[32];
static unsigned int queued_events_count;

static MacDrvEvent *wrap_queue_event(int type, void *window, BOOL drag, BOOL barrier,
                                     int x, int y, int raw_x, int raw_y, unsigned long time)
{
    macdrv_event *event;
    MacDrvEvent *wrapper;

    require_true(queued_events_count < 32, "queue input probe overflow");
    event = &queued_events[queued_events_count++];
    memset(event, 0, sizeof(*event));
    event->type = type;
    event->window = window;
    event->deliver = INT_MAX;
    event->mouse_moved.drag = drag;
    event->mouse_moved.noncoalescible = barrier;
    event->mouse_moved.x = x;
    event->mouse_moved.y = y;
    event->mouse_moved.raw_x = raw_x;
    event->mouse_moved.raw_y = raw_y;
    event->mouse_moved.time_ms = time;
    wrapper = [MacDrvEvent new];
    wrapper->event = event;
    return [wrapper autorelease];
}

static macdrv_event *queued_at(WineEventQueue *queue, NSUInteger index)
{
    return ((MacDrvEvent *)[queue->events objectAtIndex:index])->event;
}

struct captured_hardware_input
{
    unsigned int calls;
    DWORD transport_flags;
    INPUT input;
    struct raw_mouse raw;
} captured_input;

static void NtUserSendHardwareInput(HWND hwnd, DWORD flags, INPUT *input, LPARAM raw)
{
    (void)hwnd;
    captured_input.calls++;
    captured_input.transport_flags = flags;
    captured_input.input = *input;
    captured_input.raw = *(struct raw_mouse *)raw;
}

struct rectangle { int left; int top; int right; int bottom; };
struct desktop_cursor
{
    int x;
    int y;
    unsigned int last_change;
    struct rectangle clip;
};
typedef struct desktop_shm { struct desktop_cursor cursor; } desktop_shm_t;
typedef struct input_shm { int cursor_count; user_handle_t cursor; } input_shm_t;
struct thread_input { input_shm_t *shared; };
struct desktop
{
    desktop_shm_t *shared;
    user_handle_t cursor_win;
    struct thread_input *input;
};

struct cursor_message
{
    unsigned int calls;
    user_handle_t target;
    lparam_t wparam;
    lparam_t lparam;
} cursor_message;

static struct thread_input *get_desktop_cursor_thread_input(struct desktop *desktop)
{
    return desktop->input;
}

static int is_cursor_clipped(struct desktop *desktop)
{
    (void)desktop;
    return 0;
}

static void queue_cursor_message(struct desktop *desktop, user_handle_t target, unsigned int message,
                                 lparam_t wparam, lparam_t lparam)
{
    (void)desktop;
    require_true(message == WM_WINE_SETCURSOR, "unexpected owner notification");
    cursor_message.calls++;
    cursor_message.target = target;
    cursor_message.wparam = wparam;
    cursor_message.lparam = lparam;
}

static unsigned int tick_value;
static unsigned int get_tick_count(void) { return ++tick_value; }
static int is_window_visible(user_handle_t win) { return win != 0; }
static int is_window_transparent(user_handle_t win) { (void)win; return 0; }
static user_handle_t shallow_window_from_point(struct desktop *desktop, int x, int y)
{
    (void)x;
    (void)y;
    return desktop->cursor_win;
}
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define SHARED_WRITE_BEGIN(pointer, type) { type *shared = (pointer);
#define SHARED_WRITE_END }
`;

const postTests = String.raw`
static void test_raw_delivery(void)
{
    WineApplicationController *controller = [WineApplicationController new];
    ProbeQueue *sink = [ProbeQueue new];
    WineWindow *window = [WineWindow new];
    ProbeEvent *probe = [ProbeEvent new];
    macdrv_event event;

    window.queue = sink;

    memset(&event, 0, sizeof(event));
    event.type = MOUSE_MOVED_ABSOLUTE;
    probe->event_time = 11;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    require_true(sink->delivered_count == 1, "stationary absolute move was not delivered");
    require_true(sink->delivered[0].mouse_moved.raw_x == 0 && sink->delivered[0].mouse_moved.raw_y == 0,
                 "stationary fallback RawInput is not zero");

    [sink clear];
    controller->rawMouseMoveDeltaX = 0;
    controller->rawMouseMoveDeltaY = 0;
    memset(&event, 0, sizeof(event));
    event.type = MOUSE_MOVED_ABSOLUTE;
    probe->delta_x = 0.5;
    probe->delta_y = -0.5;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    event.type = MOUSE_MOVED_RELATIVE;
    event.mouse_moved.x = 0;
    event.mouse_moved.y = 0;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    require_true(sink->delivered_count == 2, "first and subsequent physical raw moves were not delivered");
    require_true(sink->delivered[0].mouse_moved.raw_x == 1 && sink->delivered[0].mouse_moved.raw_y == -1 &&
                 sink->delivered[1].mouse_moved.raw_x == 1 && sink->delivered[1].mouse_moved.raw_y == -1,
                 "physical raw deltas were not retained for every move");

    [sink clear];
    controller->rawMouseMoveDeltaX = 0;
    controller->rawMouseMoveDeltaY = 0;
    probe->delta_x = 0.25;
    probe->delta_y = 0;
    memset(&event, 0, sizeof(event));
    event.type = MOUSE_MOVED_RELATIVE;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    require_true(sink->delivered_count == 0, "subpixel raw remainder unexpectedly emitted a movement");
    probe->delta_x = 0;
    event.type = MOUSE_MOVED_ABSOLUTE;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    probe->delta_x = 0.25;
    event.type = MOUSE_MOVED_RELATIVE;
    [controller applyProductionRawDelivery:probe event:&event scale:2 targetWindow:window drag:FALSE];
    require_true(sink->delivered_count == 2 && sink->delivered[0].mouse_moved.raw_x == 0 &&
                 sink->delivered[1].mouse_moved.raw_x == 1,
                 "raw fractional accumulator was reset by an absolute baseline");
}

static void test_queue_coalescing(void)
{
    WineEventQueue *queue = [WineEventQueue new];
    void *window = (void *)0x1234;

    queue->events = [NSMutableArray new];
    queue->eventsLock = [NSLock new];

    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 2, 3, 2, 3, 1)];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 4, 5, 4, 5, 2)];
    require_true([queue->events count] == 1 && queued_at(queue, 0)->mouse_moved.x == 6 &&
                 queued_at(queue, 0)->mouse_moved.y == 8 && queued_at(queue, 0)->mouse_moved.raw_x == 6 &&
                 queued_at(queue, 0)->mouse_moved.raw_y == 8,
                 "physical raw relative moves did not coalesce with their legacy deltas");

    [queue->events removeAllObjects];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 4, 5, 7, 8, 3)];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_ABSOLUTE, window, FALSE, FALSE, 100, 200, 0, 0, 4)];
    require_true([queue->events count] == 1 && queued_at(queue, 0)->type == MOUSE_MOVED_ABSOLUTE &&
                 queued_at(queue, 0)->mouse_moved.x == 100 && queued_at(queue, 0)->mouse_moved.y == 200 &&
                 queued_at(queue, 0)->mouse_moved.raw_x == 7 && queued_at(queue, 0)->mouse_moved.raw_y == 8,
                 "absolute legacy ordering discarded prior physical raw delta");

    [queue->events removeAllObjects];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_ABSOLUTE, window, FALSE, FALSE, 100, 200, 0, 0, 5)];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 4, 5, 7, 8, 6)];
    require_true([queue->events count] == 1 && queued_at(queue, 0)->type == MOUSE_MOVED_ABSOLUTE &&
                 queued_at(queue, 0)->mouse_moved.x == 104 && queued_at(queue, 0)->mouse_moved.y == 205 &&
                 queued_at(queue, 0)->mouse_moved.raw_x == 7 && queued_at(queue, 0)->mouse_moved.raw_y == 8,
                 "relative legacy ordering discarded physical raw delta");

    [queue->events removeAllObjects];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 1, 1, INT_MAX, 0, 7)];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 1, 1, 1, 0, 8)];
    require_true([queue->events count] == 2 && queued_at(queue, 0)->mouse_moved.raw_x == INT_MAX &&
                 queued_at(queue, 1)->mouse_moved.raw_x == 1,
                 "RawInput coalescing overflow was not retained as ordered events");

    [queue->events removeAllObjects];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, FALSE, 1, 1, 1, 1, 9)];
    [queue postEventObject:wrap_queue_event(MOUSE_MOVED_RELATIVE, window, FALSE, TRUE, 1, 1, 1, 1, 10)];
    require_true([queue->events count] == 2, "noncoalescible lifecycle boundary merged motion events");
}

static void test_raw_transport(void)
{
    macdrv_event event;

    memset(&event, 0, sizeof(event));
    event.type = MOUSE_MOVED_ABSOLUTE;
    event.mouse_moved.x = 30;
    event.mouse_moved.y = 40;
    event.mouse_moved.raw_x = 0;
    event.mouse_moved.raw_y = 0;
    event.mouse_moved.time_ms = 21;
    memset(&captured_input, 0, sizeof(captured_input));
    macdrv_mouse_moved((HWND)0x1, &event);
    require_true(captured_input.calls == 1 && captured_input.transport_flags == SEND_HWMSG_RAWINPUT &&
                 captured_input.raw.count == 1 && captured_input.raw.data[0].x == 0 &&
                 captured_input.raw.data[0].y == 0,
                 "stationary move did not retain zero RawInput transport");

    event.type = MOUSE_MOVED_RELATIVE;
    event.mouse_moved.raw_x = 7;
    event.mouse_moved.raw_y = -9;
    memset(&captured_input, 0, sizeof(captured_input));
    macdrv_mouse_moved((HWND)0x1, &event);
    require_true(captured_input.raw.count == 1 && captured_input.raw.data[0].x == 7 &&
                 captured_input.raw.data[0].y == -9,
                 "subsequent move did not retain physical RawInput delta");

    memset(&event, 0, sizeof(event));
    event.mouse_button.button = 0;
    event.mouse_button.pressed = TRUE;
    event.mouse_button.x = 11;
    event.mouse_button.y = 12;
    event.mouse_button.time_ms = 22;
    memset(&captured_input, 0, sizeof(captured_input));
    macdrv_mouse_button((HWND)0x1, &event);
    require_true(captured_input.transport_flags == SEND_HWMSG_RAWINPUT && captured_input.raw.count == 0 &&
                 captured_input.input.mi.time == 22,
                 "button delivery did not preserve zero-count RawInput transport");

    memset(&event, 0, sizeof(event));
    event.mouse_scroll.y_scroll = 120;
    event.mouse_scroll.x_scroll = -120;
    event.mouse_scroll.x = 21;
    event.mouse_scroll.y = 22;
    event.mouse_scroll.time_ms = 23;
    memset(&captured_input, 0, sizeof(captured_input));
    macdrv_mouse_scroll((HWND)0x1, &event);
    require_true(captured_input.calls == 2 && captured_input.transport_flags == SEND_HWMSG_RAWINPUT &&
                 captured_input.raw.count == 0 && captured_input.input.mi.time == 23,
                 "wheel delivery did not preserve zero-count RawInput transport");
}

static void test_owner_sync(void)
{
    desktop_shm_t desktop_shm = { .cursor = { .x = 17, .y = 29, .last_change = 41,
        .clip = { 1, 2, 300, 400 } } };
    input_shm_t input_shm = { .cursor_count = 0, .cursor = 0x61 };
    struct thread_input input = { .shared = &input_shm };
    struct desktop desktop = { .shared = &desktop_shm, .cursor_win = 0x42, .input = &input };
    struct desktop_cursor before = desktop_shm.cursor;

    memset(&cursor_message, 0, sizeof(cursor_message));
    require_true(update_desktop_cursor_window(&desktop, 0x42, 1) == 0,
                 "same-owner synchronization unexpectedly changed owner");
    require_true(!memcmp(&before, &desktop_shm.cursor, sizeof(before)),
                 "owner synchronization changed cursor position, time, or clip");
    require_true(cursor_message.calls == 1 && cursor_message.target == 0x42 &&
                 cursor_message.wparam == 0x42 && cursor_message.lparam == 0x61,
                 "same-owner synchronization did not re-notify cursor payload");
}

int main(void)
{
    @autoreleasepool
    {
        test_raw_delivery();
        test_queue_coalescing();
        test_raw_transport();
        test_owner_sync();
        puts("cursor input regression passed");
    }
    return 0;
}
`;

const temporaryDirectory = mkdtempSync(join(tmpdir(), "wine-mac-cursor-input-"));
const sourceFile = join(temporaryDirectory, "cursor_input_harness.m");
const executable = join(temporaryDirectory, "cursor_input_harness");
const harness = [
  sharedPrelude,
  rawDelivery,
  sharedMiddle,
  queueMethod,
  sharedPostQueue,
  sendMouseInput,
  mouseMoved,
  mouseButton,
  mouseScroll,
  ownerWindowUpdate,
  postTests,
].join("\n");

try {
  writeFileSync(sourceFile, harness);
  run("xcrun", ["clang", "-fno-objc-arc", "-Werror", sourceFile, "-framework", "Foundation", "-o", executable]);
  const result = run(executable, [], { cwd: temporaryDirectory });
  process.stdout.write(result.stdout);
} finally {
  rmSync(temporaryDirectory, { force: true, recursive: true });
}
