import AppKit

let app = NSApplication.shared

// .accessory にすることで Dock にアイコンを表示せず、メニューバー専用アプリとして動作する。
// Info.plist の LSUIElement=true と合わせて、メニューバー常駐アプリを実現。
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// AppKit のイベントループを開始。ここでアプリが起動し、終了するまで戻らない。
app.run()
