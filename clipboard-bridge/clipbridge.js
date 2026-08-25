// clipbridge.js —— macOS 侧常驻剪贴板监听(JXA / JavaScript for Automation)
//
// 为什么不用 AppleScript:
//   AppleScript 检测剪贴板变化只能靠 `clipboard info`,而它为了报告各数据类型的字节数
//   会真的把图渲染一遍 —— 实测每轮要花约 1.5 秒,且只要剪贴板里有图就一直在烧 CPU。
//   NSPasteboard 的 changeCount 是个 O(1) 的整数,不触发任何渲染,这才是正确的原语。
//
// 隐私:只镜像图片,绝不镜像剪贴板文本 —— 避免密码管理器里复制的东西被写到磁盘。
//
// 落盘文件(均在 ~/.clipboard-bridge/):
//   clipboard.png   当前剪贴板里的图片
//   targets         存在且内容为 image/png 时,表示「现在有图可粘」
//   alive           心跳,约每 5 秒更新;垫片据此判断桥接是否还活着
//   clipbridge.log  状态与错误
//
// 用法:
//   osascript -l JavaScript clipbridge.js              常驻
//   osascript -l JavaScript clipbridge.js --selftest   前台自检一次后退出

ObjC.import('AppKit')

var POLL_SECONDS = 0.2
var HEARTBEAT_SECONDS = 5
// 去抖:有些截图/剪贴板工具分多步写入(先清空再写数据),每一步都会让 changeCount 自增。
// 若不等它稳定就抓,一次截图会触发多次捕获 —— 中间那次往往是「空剪贴板」,会把
// targets 删掉再重建,表现为 targets 反复生成,并且此刻按 Ctrl+V 会「没反应」。
var SETTLE_SECONDS = 0.12
var SETTLE_MAX_ROUNDS = 10
var LOG_CAP_BYTES = 262144
var PNG_FILE_TYPE = 4        // NSBitmapImageFileTypePNG
var IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp|tiff?|heic)$/i

var fm = $.NSFileManager.defaultManager

function nil(x) { return !x || x.isNil() }

function writeText(text, path) {
    return $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, $())
}

function remove(path) { fm.removeItemAtPathError(path, $()) }

function capLog(path) {
    if (!fm.fileExistsAtPath(path)) return
    var attrs = fm.attributesOfItemAtPathError(path, $())
    if (nil(attrs)) return
    var size = attrs.objectForKey('NSFileSize')
    if (!nil(size) && size.longLongValue > LOG_CAP_BYTES) writeText('', path)
}

// NSDate.description 固定输出 UTC,和宿主机本地时间对不上,查日志时很容易看错。
var stampFormatter = null
function timestamp() {
    if (stampFormatter === null) {
        stampFormatter = $.NSDateFormatter.alloc.init
        stampFormatter.dateFormat = 'yyyy-MM-dd HH:mm:ss'   // 默认用系统本地时区
    }
    return ObjC.unwrap(stampFormatter.stringFromDate($.NSDate.date))
}

function logLine(logPath, message) {
    var stamp = timestamp()
    var prev = $.NSString.stringWithContentsOfFileEncodingError(logPath, $.NSUTF8StringEncoding, $())
    var body = nil(prev) ? '' : ObjC.unwrap(prev)
    writeText(body + '[' + stamp + '] ' + message + '\n', logPath)
}

// 剪贴板里的图片 -> NSData(PNG)。拿不到返回 null。
function pngFromClipboard(pb) {
    var direct = pb.dataForType('public.png')
    if (!nil(direct)) return direct

    var tiff = pb.dataForType('public.tiff')
    if (!nil(tiff)) {
        var rep = $.NSBitmapImageRep.imageRepWithData(tiff)
        if (!nil(rep)) {
            var out = rep.representationUsingTypeProperties(PNG_FILE_TYPE, $.NSDictionary.dictionary)
            if (!nil(out)) return out
        }
    }

    // 访达里 ⌘C 复制的图片文件
    var urlText = pb.stringForType('public.file-url')
    if (!nil(urlText)) {
        var url = $.NSURL.URLWithString(urlText)
        if (!nil(url)) {
            var path = ObjC.unwrap(url.path)
            if (path && IMAGE_EXT.test(path)) {
                var fileData = $.NSData.dataWithContentsOfFile(path)
                if (!nil(fileData)) {
                    var fileRep = $.NSBitmapImageRep.imageRepWithData(fileData)
                    if (!nil(fileRep)) {
                        var converted = fileRep.representationUsingTypeProperties(
                            PNG_FILE_TYPE, $.NSDictionary.dictionary)
                        if (!nil(converted)) return converted
                    }
                }
            }
        }
    }
    return null
}

// 返回 'ok:<字节数>' / 'noimage' / 错误描述
function capture(pb, pngPath, tgtPath) {
    // 先撤下 targets,避免沙箱在写入过程中读到半张图
    remove(tgtPath)

    var data = pngFromClipboard(pb)
    if (data === null) {
        remove(pngPath)
        return 'noimage'
    }
    // writeToFileAtomically 内部就是先写临时文件再 rename,本身即原子操作
    if (!data.writeToFileAtomically(pngPath, true)) return '写入 clipboard.png 失败'
    // targets 最后写,保证「宣告有图」时图已经完整就位
    if (!writeText('image/png', tgtPath)) return '写入 targets 失败'
    return 'ok:' + data.length
}

function clipboardTypes(pb) {
    var out = []
    var types = pb.types
    if (nil(types)) return out
    for (var i = 0; i < types.count; i++) out.push(ObjC.unwrap(types.objectAtIndex(i)))
    return out
}

function run(argv) {
    var home = ObjC.unwrap($.NSHomeDirectory())
    var dir = home + '/.clipboard-bridge/'
    var pngPath = dir + 'clipboard.png'
    var tgtPath = dir + 'targets'
    var alivePath = dir + 'alive'
    var logPath = dir + 'clipbridge.log'

    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), $())

    var pb = $.NSPasteboard.generalPasteboard

    if (argv.indexOf('--selftest') >= 0) {
        var lines = []
        lines.push('changeCount : ' + pb.changeCount)
        var t = clipboardTypes(pb)
        lines.push('数据类型    : ' + (t.length ? t.join(', ') : '(空)'))
        var t0 = $.NSDate.date
        var result = capture(pb, pngPath, tgtPath)
        var cost = Math.round(-t0.timeIntervalSinceNow * 1000)
        lines.push('抓取结果    : ' + result + '  (耗时 ' + cost + ' ms)')
        var t1 = $.NSDate.date
        for (var k = 0; k < 20; k++) pb.changeCount
        lines.push('changeCount : 20 次共 ' + Math.round(-t1.timeIntervalSinceNow * 1000) + ' ms')
        lines.push('轮询周期    : ' + POLL_SECONDS + ' s,去抖 ' + SETTLE_SECONDS +
            ' s,心跳 ' + HEARTBEAT_SECONDS + ' s(墙钟)')
        return lines.join('\n')
    }

    capLog(logPath)
    capLog(dir + 'clipbridge.err')
    logLine(logPath, '监听启动(JXA / changeCount)')

    var lastChange = -1
    var lastNote = ''
    // 心跳按墙钟时间算,不能按循环轮次算 —— 抓图那一轮会明显变慢,
    // 按轮次数会让心跳间隔跟着抻长(旧版就栽在这:名义 5 秒,实测 12~20 秒)。
    var lastHeartbeat = $.NSDate.distantPast
    while (true) {
        if (-lastHeartbeat.timeIntervalSinceNow >= HEARTBEAT_SECONDS) {
            writeText('', alivePath)
            lastHeartbeat = $.NSDate.date
        }

        var change = pb.changeCount
        if (change !== lastChange) {
            // 等 changeCount 不再变动,把一次截图的多步写入收敛成一次捕获
            for (var round = 0; round < SETTLE_MAX_ROUNDS; round++) {
                $.NSThread.sleepForTimeInterval(SETTLE_SECONDS)
                var settled = pb.changeCount
                if (settled === change) break
                change = settled
            }
            lastChange = change
            var outcome = capture(pb, pngPath, tgtPath)
            // 带上 changeCount:同一次截图若被剪贴板分多次写入(有些截图工具会先清空
            // 再写数据),这里就能看出触发了几次捕获、分别对应哪个 changeCount。
            if (outcome.indexOf('ok:') === 0) {
                logLine(logPath, '已捕获剪贴板图片 ' + outcome.substring(3) +
                    ' 字节 (changeCount=' + change + ')')
                lastNote = ''
            } else if (outcome !== 'noimage' && outcome !== lastNote) {
                logLine(logPath, outcome + ' (changeCount=' + change + ')')
                lastNote = outcome
            }
        }

        $.NSThread.sleepForTimeInterval(POLL_SECONDS)
    }
}
