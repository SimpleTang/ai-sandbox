-- clipbridge.applescript —— macOS 侧常驻剪贴板监听
--
-- 作用:盯着 macOS 剪贴板,一旦里面出现「图片」,就把它写成 PNG 落到共享目录
--       ~/.clipboard-bridge/clipboard.png,供沙箱里的 xclip 垫片读取。
--
-- 隐私:只镜像图片,绝不镜像剪贴板文本 —— 避免密码管理器里复制的东西被写到磁盘。
--
-- 落盘文件(均在 ~/.clipboard-bridge/):
--   clipboard.png   当前剪贴板里的图片
--   targets         存在且内容为 image/png 时,表示「现在有图可粘」
--   alive           心跳,约每 5 秒 touch 一次;垫片据此判断桥接是否还活着
--   clipbridge.log  状态与错误(相同内容不重复记,不会无限增长)

on run
	set homePath to POSIX path of (path to home folder)
	set bridgeDir to homePath & ".clipboard-bridge/"
	do shell script "mkdir -p " & quoted form of bridgeDir
	set pngPath to bridgeDir & "clipboard.png"
	set tgtPath to bridgeDir & "targets"
	set alivePath to bridgeDir & "alive"
	set logPath to bridgeDir & "clipbridge.log"

	-- 日志封顶:超过 256 KB 就截断。launchd 的 stderr(clipbridge.err)会收到
	-- ImageIO 的 "JP2 color space" 之类噪音,每抓一张图一行,不封顶会长期累积。
	try
		do shell script "for f in " & quoted form of logPath & " " & ¬
			quoted form of (bridgeDir & "clipbridge.err") & "; do " & ¬
			"[ -f \"$f\" ] && [ \"$(wc -c < \"$f\")\" -gt 262144 ] && : > \"$f\"; done; true"
	end try

	set lastSig to "<init>"
	set lastNote to ""
	set tick to 0
	set lastHeartbeat to (current date) - 60
	set lastNote to my logLine(logPath, "监听启动", lastNote)

	repeat
		-- 心跳按墙钟时间算,不能按轮次算:clipboard info 那一步的耗时随剪贴板内容
		-- 大幅波动(有图时约 1.5 秒),按轮次数会让心跳间隔被抻到 12~20 秒。
		if (current date) - lastHeartbeat ≥ 5 then
			try
				do shell script "touch " & quoted form of alivePath
				set lastHeartbeat to (current date)
			end try
		end if

		-- 变化检测:用 clipboard info 里各数据类型的字节数拼一个签名,没变就什么都不做,
		-- 避免每 0.5 秒去复制一份图像数据。
		set sig to ""
		set sigOK to true
		try
			repeat with p in (clipboard info)
				set pr to contents of p
				set sig to sig & ((item 2 of pr) as text) & "|"
			end repeat
		on error errMsg number errNum
			set sigOK to false
			set lastNote to my logLine(logPath, ¬
				"读取 clipboard info 失败: " & errMsg & " (" & errNum & ")", lastNote)
		end try

		set shouldSync to false
		if sigOK then
			if sig is not lastSig then
				set lastSig to sig
				set shouldSync to true
			end if
		else
			-- 拿不到类型清单时不能就此停摆(否则首轮之后永远不再同步),改为每 5 秒盲试一次
			if tick mod 10 is 0 then set shouldSync to true
		end if

		if shouldSync then
			set syncResult to my syncClipboard(pngPath, tgtPath)
			if syncResult is "ok" then
				set lastNote to my logLine(logPath, "已捕获剪贴板图片", lastNote)
			else if syncResult is not "noimage" then
				set lastNote to my logLine(logPath, syncResult, lastNote)
			end if
		end if

		set tick to tick + 1
		delay 0.5
	end repeat
end run

-- 返回 "ok"(抓到并落位) / "noimage"(剪贴板里不是图,属常态) / 其他(错误描述,会进日志)
on syncClipboard(pngPath, tgtPath)
	set tmpPath to pngPath & ".tmp"
	-- 先撤下 targets,避免沙箱在写入过程中读到半张图
	do shell script "rm -f " & quoted form of tgtPath

	set imgData to missing value
	set srcFile to ""

	-- 情况 1:剪贴板里直接是图像数据(截图、网页里复制图片等)
	try
		set imgData to (the clipboard as «class PNGf»)
	end try

	-- 情况 2:剪贴板里是「图片文件」(在访达里 ⌘C 复制的文件)
	if imgData is missing value then
		try
			set srcFile to POSIX path of ((the clipboard as «class furl») as alias)
		end try
	end if

	if imgData is missing value and srcFile is "" then
		do shell script "rm -f " & quoted form of pngPath & " " & quoted form of tmpPath
		return "noimage"
	end if

	if imgData is not missing value then
		try
			my writeData(imgData, tmpPath)
		on error errMsg number errNum
			return "写入临时文件失败: " & errMsg & " (" & errNum & ")"
		end try
	else
		if not my isImagePath(srcFile) then
			do shell script "rm -f " & quoted form of pngPath & " " & quoted form of tmpPath
			return "noimage"
		end if
		try
			do shell script "/usr/bin/sips -s format png " & quoted form of srcFile & ¬
				" --out " & quoted form of tmpPath & " >/dev/null 2>&1"
		on error errMsg number errNum
			return "sips 转换失败: " & errMsg & " (" & errNum & ")"
		end try
	end if

	-- targets 最后写,保证「宣告有图」时图已经完整就位
	try
		do shell script "mv -f " & quoted form of tmpPath & " " & quoted form of pngPath
		my writeText("image/png", tgtPath)
	on error errMsg number errNum
		return "落位失败: " & errMsg & " (" & errNum & ")"
	end try

	return "ok"
end syncClipboard

on isImagePath(p)
	set lc to do shell script "printf %s " & quoted form of p & " | tr 'A-Z' 'a-z'"
	repeat with ext in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic"}
		if lc ends with (ext as text) then return true
	end repeat
	return false
end isImagePath

-- 相同内容不重复记录,长期运行也不会把日志撑爆
on logLine(logPath, message, lastNote)
	if message is lastNote then return lastNote
	try
		do shell script "printf '[%s] %s\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" " & ¬
			quoted form of message & " >> " & quoted form of logPath
	end try
	return message
end logLine

on writeData(theData, thePath)
	set fh to open for access (POSIX file thePath) with write permission
	try
		set eof fh to 0
		write theData to fh
		close access fh
	on error e number n
		try
			close access fh
		end try
		error e number n
	end try
end writeData

on writeText(theText, thePath)
	set fh to open for access (POSIX file thePath) with write permission
	try
		set eof fh to 0
		write theText to fh as «class utf8»
		close access fh
	on error e number n
		try
			close access fh
		end try
		error e number n
	end try
end writeText
