import AppKit

/// SearchWindow の横に表示される Quick Look パネル。
/// 選択行を指す吹き出し（三角矢印）付き。上下移動で矢印が追従する。
/// テキストは固定サイズ、画像はアスペクト比に合わせてパネルサイズを可変にする。
@MainActor
final class QuickLookPanel: NSPanel {
    private enum Layout {
        // テキストモード（固定サイズ）
        static let textWidth: CGFloat = 480
        static let textHeight: CGFloat = 440
        static let textHPadding: CGFloat = 16
        static let textVPadding: CGFloat = 8
        // 画像モード（最大サイズ、画像に合わせて可変）
        static let maxImageWidth: CGFloat = 640
        static let maxImageHeight: CGFloat = 560
        static let minContentSize: CGFloat = 200
        static let imagePadding: CGFloat = 8
        // 共通
        static let arrowWidth: CGFloat = 10
        static let arrowHeight: CGFloat = 20
        static let cornerRadius: CGFloat = 12
        static let gap: CGFloat = 4
    }

    private let visualEffect = NSVisualEffectView()
    private let containerView = NSView()
    private let imageView = NSImageView()
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    private var arrowOnLeft = true
    private var arrowCenterY: CGFloat = Layout.textHeight / 2
    private var containerLeading: NSLayoutConstraint!
    private var containerTrailing: NSLayoutConstraint!

    /// 現在のコンテンツ領域サイズ（矢印を含まない）。
    /// テキストモードでは固定値、画像モードでは画像のアスペクト比に応じて変動する。
    private var currentContentWidth: CGFloat = Layout.textWidth
    private var currentContentHeight: CGFloat = Layout.textHeight

    init() {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: Layout.textHPadding, height: Layout.textVPadding)
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        self.textView = tv

        let size = NSSize(width: Layout.textWidth + Layout.arrowWidth, height: Layout.textHeight)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        setupUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        visualEffect.material = .sheet
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        contentView = visualEffect

        // コンテンツコンテナ（矢印分だけオフセット）
        containerView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(containerView)

        containerLeading = containerView.leadingAnchor.constraint(
            equalTo: visualEffect.leadingAnchor, constant: Layout.arrowWidth)
        containerTrailing = containerView.trailingAnchor.constraint(
            equalTo: visualEffect.trailingAnchor)
        NSLayoutConstraint.activate([
            containerLeading,
            containerTrailing,
            containerView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        // 画像（パディング付き — プレビューウィンドウとして視認できるように余白を確保）
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.isHidden = true
        containerView.addSubview(imageView)

        // テキスト
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        containerView.addSubview(scrollView)

        let p = Layout.imagePadding
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: p),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: p),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -p),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -p),

            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        updateMask()
    }

    // MARK: - Mask (rounded rect + arrow)

    /// NSVisualEffectView.maskImage を使い、角丸 + 吹き出し矢印の形にクリッピング。
    private func updateMask() {
        let size = visualEffect.bounds.size
        guard size.width > 0 && size.height > 0 else { return }

        let maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            let contentRect: NSRect
            if self.arrowOnLeft {
                contentRect = NSRect(x: Layout.arrowWidth, y: 0,
                                     width: self.currentContentWidth, height: rect.height)
            } else {
                contentRect = NSRect(x: 0, y: 0,
                                     width: self.currentContentWidth, height: rect.height)
            }
            let roundedPath = NSBezierPath(roundedRect: contentRect,
                                           xRadius: Layout.cornerRadius,
                                           yRadius: Layout.cornerRadius)
            roundedPath.fill()

            let ay = self.arrowCenterY
            let half = Layout.arrowHeight / 2
            let arrowPath = NSBezierPath()
            if self.arrowOnLeft {
                arrowPath.move(to: NSPoint(x: Layout.arrowWidth, y: ay + half))
                arrowPath.line(to: NSPoint(x: 0, y: ay))
                arrowPath.line(to: NSPoint(x: Layout.arrowWidth, y: ay - half))
            } else {
                let right = rect.width
                arrowPath.move(to: NSPoint(x: right - Layout.arrowWidth, y: ay + half))
                arrowPath.line(to: NSPoint(x: right, y: ay))
                arrowPath.line(to: NSPoint(x: right - Layout.arrowWidth, y: ay - half))
            }
            arrowPath.close()
            arrowPath.fill()

            return true
        }

        visualEffect.maskImage = maskImage
    }

    private func updateArrowSide(_ onLeft: Bool) {
        guard onLeft != arrowOnLeft else { return }
        arrowOnLeft = onLeft
        if arrowOnLeft {
            containerLeading.constant = Layout.arrowWidth
            containerTrailing.constant = 0
        } else {
            containerLeading.constant = 0
            containerTrailing.constant = -Layout.arrowWidth
        }
    }

    // MARK: - Content

    /// 画像をセットし、パネルサイズを画像のアスペクト比に合わせて調整する。
    func showImage(_ image: NSImage) {
        let rep = image.representations.first
        let pixelW = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        let pixelH = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))

        // パディング分を差し引いた描画可能領域で計算
        let pad2 = Layout.imagePadding * 2
        let availW = Layout.maxImageWidth - pad2
        let availH = Layout.maxImageHeight - pad2

        // 描画可能領域内にアスペクト比を維持してフィット（拡大はしない）
        let scale = min(availW / pixelW, availH / pixelH, 1.0)
        let fitW = ceil(pixelW * scale)
        let fitH = ceil(pixelH * scale)

        // パネルサイズ = 画像サイズ + パディング
        currentContentWidth = max(fitW + pad2, Layout.minContentSize)
        currentContentHeight = max(fitH + pad2, Layout.minContentSize)
        applyWindowSize()

        imageView.image = image
        imageView.isHidden = false
        scrollView.isHidden = true
    }

    /// テキストをセットし、パネルサイズを固定サイズに戻す。
    /// テキストのレイアウトは finalizeTextLayout() で行う（ウィンドウリサイズ後に呼ぶ）。
    func showText(_ text: String) {
        currentContentWidth = Layout.textWidth
        currentContentHeight = Layout.textHeight
        applyWindowSize()

        textView.string = text
        scrollView.isHidden = false
        imageView.isHidden = true
    }

    /// ウィンドウフレーム確定後にテキストを再レイアウトし、先頭にスクロールする。
    func finalizeTextLayout() {
        guard !scrollView.isHidden else { return }
        // レイアウトを強制的に確定してからスクロール位置をリセット
        visualEffect.layoutSubtreeIfNeeded()
        let width = scrollView.contentSize.width
        textView.setFrameSize(NSSize(width: width, height: 0))
        textView.sizeToFit()
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// currentContentWidth/Height をウィンドウサイズに反映する。
    /// 実際のフレーム設定は updatePosition / show 内の setFrame で行う。
    private func applyWindowSize() {
        let size = NSSize(width: currentContentWidth + Layout.arrowWidth, height: currentContentHeight)
        setContentSize(size)
    }

    // MARK: - Positioning

    /// 初回表示。ポップアップアニメーション付き。
    func show(relativeTo searchWindowFrame: NSRect, pointingAt rowScreenRect: NSRect, animated: Bool = true) {
        let (targetFrame, newArrowY, newArrowOnLeft) = calculateLayout(
            relativeTo: searchWindowFrame, pointingAt: rowScreenRect)

        updateArrowSide(newArrowOnLeft)
        arrowCenterY = newArrowY
        setFrame(targetFrame, display: true)
        updateMask()

        if animated && !isVisible {
            alphaValue = 0
            orderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
            if let layer = contentView?.layer {
                let anim = CABasicAnimation(keyPath: "transform.scale")
                anim.fromValue = 0.92
                anim.toValue = 1.0
                anim.duration = 0.18
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(anim, forKey: "popup")
            }
        } else {
            alphaValue = 1
            orderFront(nil)
        }
    }

    /// 選択行変更に伴う位置・矢印・サイズの更新。
    /// 高速スクロールでも正確に追従するよう、アニメーションなしで即座に反映する。
    func updatePosition(relativeTo searchWindowFrame: NSRect, pointingAt rowScreenRect: NSRect) {
        let (targetFrame, newArrowY, newArrowOnLeft) = calculateLayout(
            relativeTo: searchWindowFrame, pointingAt: rowScreenRect)

        updateArrowSide(newArrowOnLeft)
        arrowCenterY = newArrowY
        setFrame(targetFrame, display: true)
        updateMask()
    }

    /// ポップアウトアニメーション付きで閉じる。
    func dismissAnimated() {
        if let layer = contentView?.layer {
            let anim = CABasicAnimation(keyPath: "transform.scale")
            anim.fromValue = 1.0
            anim.toValue = 0.92
            anim.duration = 0.12
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "dismiss")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            self.contentView?.layer?.removeAllAnimations()
        })
    }

    // MARK: - Layout calculation

    private func calculateLayout(
        relativeTo searchWindowFrame: NSRect,
        pointingAt rowScreenRect: NSRect
    ) -> (frame: NSRect, arrowCenterY: CGFloat, arrowOnLeft: Bool) {
        let w = currentContentWidth + Layout.arrowWidth
        let h = currentContentHeight

        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(searchWindowFrame.origin)
        }) ?? NSScreen.main else {
            return (NSRect(origin: .zero, size: NSSize(width: w, height: h)),
                    h / 2, true)
        }
        let screenFrame = screen.visibleFrame

        // 左右の配置決定
        let rightX = searchWindowFrame.maxX + Layout.gap
        let leftX = searchWindowFrame.minX - w - Layout.gap
        let onRight = (rightX + w <= screenFrame.maxX) || (leftX < screenFrame.minX)
        let x = onRight ? rightX : leftX
        let newArrowOnLeft = onRight

        // 縦位置: 選択行の中心に合わせ、画面内にクランプ
        let rowCenterY = rowScreenRect.isEmpty ? searchWindowFrame.midY : rowScreenRect.midY
        let idealY = rowCenterY - h / 2
        let clampedY = max(screenFrame.minY, min(idealY, screenFrame.maxY - h))

        // パネル内での矢印Y座標（角丸の内側に収める）
        let arrowInPanel = rowCenterY - clampedY
        let minArrow = Layout.cornerRadius + Layout.arrowHeight / 2
        let maxArrow = h - Layout.cornerRadius - Layout.arrowHeight / 2
        let clampedArrow = max(minArrow, min(arrowInPanel, maxArrow))

        return (NSRect(x: x, y: clampedY, width: w, height: h), clampedArrow, newArrowOnLeft)
    }
}
