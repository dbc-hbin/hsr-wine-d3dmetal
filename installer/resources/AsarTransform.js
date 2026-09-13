(function () {
  "use strict";

  function staticPropertyName(name) {
    return ts.isIdentifier(name) || ts.isStringLiteralLike(name) ? name.text : undefined;
  }

  function property(object, name) {
    return object.properties.find(function (item) {
      return ts.isPropertyAssignment(item) && staticPropertyName(item.name) === name;
    });
  }

  function stringLiteralValue(node) {
    return ts.isStringLiteralLike(node) ? node.text : undefined;
  }

  function visit(node, callback) {
    callback(node);
    ts.forEachChild(node, function (child) { visit(child, callback); });
  }

  function wineDistribution(node) {
    if (!ts.isObjectLiteralExpression(node)) return undefined;
    var id = property(node, "id");
    var displayName = property(node, "displayName");
    var remoteUrl = property(node, "remoteUrl");
    var attributes = property(node, "attributes");
    if (!id || !displayName || !remoteUrl || !attributes || !ts.isObjectLiteralExpression(attributes.initializer)) return undefined;
    var renderBackend = property(attributes.initializer, "renderBackend");
    if (!renderBackend || stringLiteralValue(id.initializer) === undefined || stringLiteralValue(displayName.initializer) === undefined || stringLiteralValue(remoteUrl.initializer) === undefined || stringLiteralValue(renderBackend.initializer) === undefined) return undefined;
    return { id: stringLiteralValue(id.initializer), renderBackend: stringLiteralValue(renderBackend.initializer), node: node };
  }

  function parse(source) {
    var sourceFile = ts.createSourceFile("frontend.js", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    if (sourceFile.parseDiagnostics.length) throw new Error(ts.flattenDiagnosticMessageText(sourceFile.parseDiagnostics[0].messageText, "\n"));
    return sourceFile;
  }

  function text(node, sourceFile) {
    return node.getText(sourceFile);
  }

  function applyChanges(source, changes) {
    changes.sort(function (left, right) { return right.start - left.start; });
    var end = source.length;
    var output = source;
    for (var index = 0; index < changes.length; index += 1) {
      var change = changes[index];
      if (change.end > end) throw new Error("overlapping structural source changes");
      output = output.slice(0, change.start) + change.replacement + output.slice(change.end);
      end = change.start;
    }
    return output;
  }

  function propertyAccessName(node) {
    return ts.isPropertyAccessExpression(node) ? node.name.text : undefined;
  }

  function isIdentifierNamed(node, name) {
    return ts.isIdentifier(node) && node.text === name;
  }

  function findTargetDistribution(sourceFile, targetId) {
    var distributions = [];
    visit(sourceFile, function (node) {
      var distribution = wineDistribution(node);
      if (distribution) distributions.push(distribution);
    });
    var targets = distributions.filter(function (distribution) { return distribution.id === targetId; });
    if (targets.length > 1) throw new Error("Wine distribution id is duplicated: " + targetId);
    return { distributions: distributions, target: targets[0] };
  }

  function catalogArray(distributions) {
    var candidates = new Map();
    distributions.forEach(function (distribution) {
      var parent = distribution.node.parent;
      if (!ts.isArrayLiteralExpression(parent)) return;
      var candidate = candidates.get(parent);
      if (!candidate) {
        candidate = { array: parent, count: 0 };
        candidates.set(parent, candidate);
      }
      candidate.count += 1;
    });
    var values = Array.from(candidates.values());
    if (!values.length) throw new Error("could not locate the Wine distribution catalog array");
    values.sort(function (left, right) { return right.count - left.count; });
    if (values.length > 1 && values[0].count === values[1].count) throw new Error("Wine distribution catalog array is ambiguous");
    return values[0].array;
  }

  function functionNodes(sourceFile) {
    var functions = [];
    visit(sourceFile, function (node) {
      if (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node)) functions.push(node);
    });
    return functions;
  }

  function findStreamingDownload(functionNode) {
    var matches = [];
    visit(functionNode.body, function (node) {
      if (!ts.isForOfStatement(node) || !node.awaitModifier) return;
      var download;
      visit(node.expression, function (child) {
        if (!ts.isCallExpression(child) || propertyAccessName(child.expression) !== "doStreamingDownload") return;
        download = child;
      });
      if (download) matches.push({ loop: node, download: download });
    });
    if (matches.length !== 1) throw new Error("could not unambiguously locate the Wine streaming download");
    return matches[0];
  }

  function wineIdentifierFromDownload(download) {
    var argument = download.arguments[0];
    if (!argument || !ts.isObjectLiteralExpression(argument)) throw new Error("Wine streaming download has no object options");
    var uri = property(argument, "uri");
    if (!uri || !ts.isPropertyAccessExpression(uri.initializer) || uri.initializer.name.text !== "remoteUrl" || !ts.isIdentifier(uri.initializer.expression)) throw new Error("Wine streaming download does not use a distribution URL");
    return uri.initializer.expression.text;
  }

  function installFunction(sourceFile) {
    var matches = functionNodes(sourceFile).filter(function (candidate) {
      if (!candidate.body) return false;
      var bodyText = text(candidate.body, sourceFile);
      return bodyText.includes("doStreamingDownload") && bodyText.includes("wine_state") && bodyText.includes("wine_tag") && bodyText.includes("./wine.tar.");
    });
    if (!matches.length) throw new Error("could not locate the Wine installation function");
    matches.sort(function (left, right) { return left.end - left.pos - (right.end - right.pos); });
    return matches[0];
  }

  function localInstallerChanges(sourceFile, targetId) {
    var functionNode = installFunction(sourceFile);
    var bodyText = text(functionNode.body, sourceFile);
    if (bodyText.includes("__yaaglD3MetalLocalArchive")) return [];

    var streaming = findStreamingDownload(functionNode);
    var wine = wineIdentifierFromDownload(streaming.download);
    if (bodyText.includes("archiveSha256") && bodyText.includes("kind===\"local\"")) {
      return bodyText.includes(targetId) ? [] : legacyLocalInstallerChanges(functionNode, sourceFile, wine, targetId);
    }
    var declarationLists = [];
    visit(functionNode.body, function (node) {
      if (ts.isVariableDeclarationList(node) && (node.flags & ts.NodeFlags.Const)) declarationLists.push(node);
    });
    var declarations = declarationLists.filter(function (list) {
      if (list.declarations.length !== 2) return false;
      var hasCompressedUrl = false;
      var hasArchivePath = false;
      list.declarations.forEach(function (declaration) {
        if (!ts.isIdentifier(declaration.name) || !declaration.initializer) return;
        var initializerText = text(declaration.initializer, sourceFile);
        hasCompressedUrl = hasCompressedUrl || initializerText.includes(wine + ".remoteUrl.endsWith(\".xz\")");
        hasArchivePath = hasArchivePath || initializerText.includes("./wine.tar.");
      });
      return hasCompressedUrl && hasArchivePath;
    });
    if (declarations.length !== 1) throw new Error("could not unambiguously locate the Wine archive declarations");

    var declarationList = declarations[0];
    var compressed = declarationList.declarations.find(function (declaration) {
      return declaration.initializer && text(declaration.initializer, sourceFile).includes(wine + ".remoteUrl.endsWith(\".xz\")");
    });
    var archive = declarationList.declarations.find(function (declaration) {
      return declaration.initializer && text(declaration.initializer, sourceFile).includes("./wine.tar.");
    });
    if (!compressed || !archive || !ts.isIdentifier(compressed.name) || !ts.isIdentifier(archive.name) || !compressed.initializer || !archive.initializer) throw new Error("Wine archive declarations have an unsupported shape");

    var marker = "__yaaglD3MetalLocalArchive";
    var target = JSON.stringify(targetId);
    var declarationReplacement = "let " + compressed.name.text + "=" + text(compressed.initializer, sourceFile) + "," + marker + "=" + wine + ".id===" + target + "&&" + wine + ".remoteUrl.startsWith(\"file:\")," + archive.name.text + "=" + marker + "?decodeURIComponent(new URL(" + wine + ".remoteUrl).pathname):" + text(archive.initializer, sourceFile);

    var deletes = [];
    visit(functionNode.body, function (node) {
      if (!ts.isAwaitExpression(node)) return;
      var expression = node.expression;
      if (!ts.isCallExpression(expression) || expression.arguments.length !== 1 || !isIdentifierNamed(expression.arguments[0], archive.name.text)) return;
      deletes.push(node);
    });
    if (deletes.length !== 1) throw new Error("could not unambiguously locate temporary Wine archive removal");

    var extractionArchives = [];
    visit(functionNode.body, function (node) {
      if (!ts.isCallExpression(node) || !ts.isCallExpression(node.parent)) return;
      if (text(node, sourceFile).includes("./wine.tar.")) extractionArchives.push(node);
    });
    if (extractionArchives.length !== 2) throw new Error("could not unambiguously locate Wine archive extraction arguments");

    return [
      { start: declarationList.getStart(sourceFile), end: declarationList.end, replacement: declarationReplacement },
      { start: streaming.loop.getStart(sourceFile), end: streaming.loop.end, replacement: "if(!" + marker + ")" + text(streaming.loop, sourceFile) },
      { start: deletes[0].getStart(sourceFile), end: deletes[0].end, replacement: "!" + marker + "&&" + text(deletes[0], sourceFile) }
    ].concat(extractionArchives.map(function (argument) {
      return { start: argument.getStart(sourceFile), end: argument.end, replacement: archive.name.text };
    }));
  }

  function legacyLocalInstallerChanges(functionNode, sourceFile, wine, targetId) {
    var localKinds = [];
    visit(functionNode.body, function (node) {
      if (!ts.isVariableDeclaration(node) || !node.initializer || !ts.isIdentifier(node.name)) return;
      if (!ts.isCallExpression(node.initializer) || node.initializer.arguments.length !== 1) return;
      var argument = node.initializer.arguments[0];
      if (ts.isPropertyAccessExpression(argument) && argument.name.text === "remoteUrl" && isIdentifierNamed(argument.expression, wine)) localKinds.push(node.name.text);
    });
    if (localKinds.length !== 1) throw new Error("could not unambiguously locate prior local Wine URL handling");
    var localKind = localKinds[0];
    var checks = [];
    visit(functionNode.body, function (node) {
      if (!ts.isIfStatement(node)) return;
      var condition = text(node.expression, sourceFile);
      var statement = text(node.thenStatement, sourceFile);
      if (condition.includes("archiveSha256") || (condition.includes(localKind + ".kind===\"local\"") && statement.includes("inside a directory being replaced"))) checks.push(node);
    });
    if (checks.length !== 3) throw new Error("could not unambiguously locate prior local Wine validation");
    var target = JSON.stringify(targetId);
    return checks.map(function (check) {
      return {
        start: check.expression.getStart(sourceFile),
        end: check.expression.end,
        replacement: "(" + text(check.expression, sourceFile) + ")&&" + wine + ".id!==" + target
      };
    });
  }

  function removePriorCatalogValidation(sourceFile, targetNode) {
    var container = targetNode;
    while (container && !ts.isFunctionDeclaration(container) && !ts.isFunctionExpression(container) && !ts.isArrowFunction(container)) container = container.parent;
    if (!container || !container.body || !ts.isBlock(container.body)) return [];
    var statements = container.body.statements;
    var returnIndex = -1;
    for (var index = 0; index < statements.length; index += 1) {
      if (ts.isReturnStatement(statements[index]) && statements[index].getStart(sourceFile) <= targetNode.getStart(sourceFile) && statements[index].end >= targetNode.end) returnIndex = index;
    }
    if (returnIndex <= 0 || returnIndex !== statements.length - 1 || !text(container.body, sourceFile).includes("archiveSha256")) return [];
    var prior = [];
    for (var position = 0; position < returnIndex; position += 1) {
      var statement = statements[position];
      if (!ts.isVariableStatement(statement) && !ts.isIfStatement(statement)) return [];
      prior.push({ start: statement.getStart(sourceFile), end: statement.end, replacement: "" });
    }
    return prior;
  }

  function launchChanges(sourceFile, targetId) {
    var matches = functionNodes(sourceFile).filter(function (candidate) {
      if (!candidate.body) return false;
      var bodyText = text(candidate.body, sourceFile);
      return bodyText.includes("resolutionCustom") && bodyText.includes(".setProps(") && bodyText.includes("GAME_RUNNING");
    });
    if (matches.length !== 1) throw new Error("could not unambiguously locate the game launch function");
    var functionNode = matches[0];
    var bodyText = text(functionNode.body, sourceFile);
    if (bodyText.includes(targetId) && bodyText.includes("-use-d3d12")) return [];

    var wineCalls = [];
    visit(functionNode.body, function (node) {
      if (ts.isCallExpression(node) && propertyAccessName(node.expression) === "setProps" && ts.isIdentifier(node.expression.expression)) wineCalls.push(node.expression.expression.text);
    });
    if (wineCalls.length !== 1) throw new Error("could not unambiguously locate the game Wine instance");

    var variables = [];
    visit(functionNode.body, function (node) {
      if (!ts.isVariableStatement(node) || node.declarationList.declarations.length !== 1) return;
      var declaration = node.declarationList.declarations[0];
      if (ts.isIdentifier(declaration.name) && declaration.initializer && ts.isArrayLiteralExpression(declaration.initializer) && declaration.initializer.elements.length === 0) variables.push({ statement: node, name: declaration.name.text });
    });
    if (variables.length !== 1) throw new Error("could not unambiguously locate game launch arguments");

    var wine = wineCalls[0];
    var target = JSON.stringify(targetId);
    return [{
      start: variables[0].statement.end,
      end: variables[0].statement.end,
      replacement: wine + ".id===" + target + "&&" + wine + ".attributes.renderBackend===\"d3dmetal\"&&" + variables[0].name + ".push(\"-use-d3d12\");"
    }];
  }

  globalThis.__asarTransform = function (source, targetId, displayName, archiveURL) {
    try {
      if (typeof source !== "string" || typeof targetId !== "string" || typeof displayName !== "string" || typeof archiveURL !== "string") throw new Error("transform arguments must be strings");
      var sourceFile = parse(source);
      var record = JSON.stringify({
        id: targetId,
        displayName: displayName,
        remoteUrl: archiveURL,
        attributes: { renderBackend: "d3dmetal", winePath: "wine" }
      });
      var catalog = findTargetDistribution(sourceFile, targetId);
      var changes = [];
      if (catalog.target) {
        changes = changes.concat(removePriorCatalogValidation(sourceFile, catalog.target.node));
        changes.push({ start: catalog.target.node.getStart(sourceFile), end: catalog.target.node.end, replacement: record });
      } else {
        var array = catalogArray(catalog.distributions);
        changes.push({ start: array.end - 1, end: array.end - 1, replacement: "," + record });
      }
      changes = changes.concat(localInstallerChanges(sourceFile, targetId));
      changes = changes.concat(launchChanges(sourceFile, targetId));
      var output = applyChanges(source, changes);
      var outputFile = parse(output);
      var outputCatalog = findTargetDistribution(outputFile, targetId);
      if (!outputCatalog.target) throw new Error("target Wine distribution was not present after transformation");
      if (findTargetDistribution(outputFile, targetId).distributions.filter(function (distribution) { return distribution.id === targetId; }).length !== 1) throw new Error("target Wine distribution was duplicated after transformation");
      if (findTargetDistribution(outputFile, targetId).distributions.some(function (distribution) { return distribution.renderBackend === "d3dmetal" && distribution.id !== targetId; })) throw new Error("obsolete D3Metal Wine distribution remained after transformation");
      return { source: output, changed: output !== source };
    } catch (error) {
      return { error: error && error.message ? error.message : String(error) };
    }
  };
}());
