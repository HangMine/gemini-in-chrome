ObjC.import('Foundation');

var countryKey = 'variations_permanent_overridden_country';
var flagsKey = 'enabled_labs_experiments';

function isKind(value, type) {
    return !!value && value.isKindOfClass(type);
}

function has(object, key) {
    return object.allKeys.containsObject($(key));
}

function readJson(path) {
    var bytes = $.NSData.dataWithContentsOfFile($(path));
    if (!isKind(bytes, $.NSData)) {
        throw new Error('无法读取 JSON 文件：' + path + '。请检查文件是否存在以及读取权限。');
    }
    var source = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(bytes, $.NSUTF8StringEncoding));
    if (typeof source !== 'string') {
        throw new Error('文件不是有效的 UTF-8 编码：' + path + '。请保留原文件。');
    }
    var data = $(source.replace(/^\uFEFF/, '')).dataUsingEncoding($.NSUTF8StringEncoding);
    var error = Ref();
    var object = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, $.NSJSONReadingMutableContainers, error);
    if (!isKind(object, $.NSDictionary)) {
        throw new Error('无法解析 JSON 对象：' + path + '。请保留原文件并检查其完整性。');
    }
    return object;
}

function getFlags(state) {
    if (!has(state, 'browser')) {
        return $.NSMutableArray.array;
    }
    var browser = state.objectForKey($('browser'));
    if (!isKind(browser, $.NSDictionary)) {
        throw new Error('配置中的 browser 不是对象，已停止修改。');
    }
    if (!has(browser, flagsKey)) {
        return $.NSMutableArray.array;
    }
    var flags = browser.objectForKey($(flagsKey));
    if (!isKind(flags, $.NSArray)) {
        throw new Error('实验开关配置不是数组，已停止修改。');
    }
    for (var i = 0; i < flags.count; i++) {
        if (!isKind(flags.objectAtIndex(i), $.NSString)) {
            throw new Error('实验开关包含非文本内容，已停止修改。');
        }
    }
    return flags;
}

function readState(path) {
    var state = readJson(path);
    getFlags(state);
    return state;
}

function filterFlags(flags, keepGlic) {
    var result = $.NSMutableArray.array;
    for (var i = 0; i < flags.count; i++) {
        var flag = flags.objectAtIndex(i);
        if (/^glic(@.*)?$(?![\s\S])/.test(ObjC.unwrap(flag)) === keepGlic) {
            result.addObject(flag);
        }
    }
    return result;
}

function ensureBrowser(state) {
    if (!has(state, 'browser')) {
        state.setObjectForKey($.NSMutableDictionary.dictionary, $('browser'));
    }
    return state.objectForKey($('browser'));
}

function writeJson(path, object) {
    if (!$.NSFileManager.defaultManager.fileExistsAtPath($(path))) {
        throw new Error('未找到用于写入的临时文件：' + path + '。配置尚未替换。');
    }
    var error = Ref();
    var data = $.NSJSONSerialization.dataWithJSONObjectOptionsError(object, 0, error);
    if (!isKind(data, $.NSData)) {
        throw new Error('无法序列化配置，原文件未修改。');
    }
    if (!data.writeToFileOptionsError($(path), 0, error)) {
        throw new Error('无法写入临时文件：' + path + '。请检查目录和文件的写入权限。');
    }
    if (!object.isEqualToDictionary(readJson(path))) {
        throw new Error('临时文件写入后校验失败，原文件未修改。');
    }
}

function install(input, output, country) {
    if (!/^[A-Za-z]{2}$(?![\s\S])/.test(country)) {
        throw new Error('地区代码必须是两个英文字母，例如 us。');
    }
    var state = readState(input);
    var flags = filterFlags(getFlags(state), false);
    flags.addObject($('glic@1'));
    state.setObjectForKey($(country.toLowerCase()), $(countryKey));
    ensureBrowser(state).setObjectForKey(flags, $(flagsKey));
    writeJson(output, state);
}

function uninstall(input, backup, output) {
    var state = readState(input);
    var original = readState(backup);
    if (has(original, countryKey)) {
        state.setObjectForKey(original.objectForKey($(countryKey)), $(countryKey));
    } else {
        state.removeObjectForKey($(countryKey));
    }

    var flags = filterFlags(getFlags(state), false);
    flags.addObjectsFromArray(filterFlags(getFlags(original), true));
    var hadBrowser = has(original, 'browser');
    var hadFlags = hadBrowser && has(original.objectForKey($('browser')), flagsKey);
    if (flags.count > 0 || hadFlags) {
        ensureBrowser(state).setObjectForKey(flags, $(flagsKey));
    } else if (has(state, 'browser')) {
        state.objectForKey($('browser')).removeObjectForKey($(flagsKey));
    }
    if (!hadBrowser && has(state, 'browser') && state.objectForKey($('browser')).count === 0) {
        state.removeObjectForKey($('browser'));
    }
    writeJson(output, state);
}

function validateManifest(manifest) {
    var version = has(manifest, 'version') ? ObjC.unwrap(manifest.objectForKey($('version'))) : undefined;
    var name = has(manifest, 'backup_file') ? ObjC.unwrap(manifest.objectForKey($('backup_file'))) : undefined;
    var hash = has(manifest, 'sha256') ? ObjC.unwrap(manifest.objectForKey($('sha256'))) : undefined;
    if (typeof version !== 'number' || version !== 1 ||
        typeof name !== 'string' || !/^Local State\.[a-f0-9]+\.bak$(?![\s\S])/.test(name) ||
        typeof hash !== 'string' || !/^[A-Fa-f0-9]{64}$(?![\s\S])/.test(hash)) {
        throw new Error('回退记录格式不正确，已停止操作。请保留 GeminiInChromeBackup 目录。');
    }
    return name + '\n' + hash.toUpperCase();
}

function run(args) {
    var action = args[0];
    if (action === 'validate' && args.length === 2) {
        readState(args[1]);
    } else if (action === 'install' && args.length === 4) {
        install(args[1], args[2], args[3]);
    } else if (action === 'uninstall' && args.length === 4) {
        uninstall(args[1], args[2], args[3]);
    } else if (action === 'manifest-create' && args.length === 4) {
        var manifest = $.NSMutableDictionary.dictionary;
        manifest.setObjectForKey($.NSNumber.numberWithInt(1), $('version'));
        manifest.setObjectForKey($(args[2]), $('backup_file'));
        manifest.setObjectForKey($(args[3]), $('sha256'));
        validateManifest(manifest);
        writeJson(args[1], manifest);
    } else if (action === 'manifest-read' && args.length === 2) {
        return validateManifest(readJson(args[1]));
    } else {
        throw new Error('配置工具的操作或参数不正确，请重新下载完整安装脚本。');
    }
    return '';
}
