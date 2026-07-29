// notch — Dynamic Island-style drop-down notification for macOS.
// Build: bun run build (or: swiftc -O -swift-version 5 -parse-as-library -o swift/notch swift/notch.swift)
// Usage: ./swift/notch "Title" "Subtitle"

import Cocoa

final class IslandView: NSView {
	override func draw(_ dirtyRect: NSRect) {
		NSColor.black.withAlphaComponent(0.92).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: 26, yRadius: 26).fill()
	}
}

final class RoundedTile: NSView {
	override func draw(_ dirtyRect: NSRect) {
		NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
	}
}

@main
@MainActor
enum NotchApp {
	static func main() {
		let args = CommandLine.arguments
		let title = args.count > 1 ? args[1] : "opencode"
		let subtitle = args.count > 2 ? args[2] : ""

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(0) }

		// --- Content ---
		let icon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
			.withSymbolConfiguration(
				NSImage.SymbolConfiguration(pointSize: 19, weight: .bold)
					.applying(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
			)

		let titleLabel = NSTextField(labelWithString: title)
		titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
		titleLabel.textColor = .white
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.maximumNumberOfLines = 1

		let subtitleLabel = NSTextField(labelWithString: subtitle)
		subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
		subtitleLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
		subtitleLabel.lineBreakMode = .byTruncatingTail
		subtitleLabel.maximumNumberOfLines = 1

		let huge = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		let titleFit = titleLabel.sizeThatFits(huge)
		let subtitleFit = subtitle.isEmpty ? NSSize.zero : subtitleLabel.sizeThatFits(huge)

		let pad: CGFloat = 20
		let tile: CGFloat = 48 // "album art" square
		let gap: CGFloat = 14
		let textGap: CGFloat = 3

		// Width hugs the content like the Dynamic Island, clamped.
		var width = pad + tile + gap + max(titleFit.width, subtitleFit.width) + pad
		width = max(340, min(560, width))
		let height: CGFloat = 92
		let clip: CGFloat = 6 // top stays hidden above the screen edge, merges with the notch

		let visibleH = height - clip
		let tileY = (visibleH - tile) / 2

		let content = IslandView(frame: NSRect(x: 0, y: 0, width: width, height: height))

		// Icon tile
		let tileView = RoundedTile(frame: NSRect(x: pad, y: tileY, width: tile, height: tile))
		if let icon {
			let iv = NSImageView(frame: NSRect(x: 13, y: 13, width: 22, height: 22))
			iv.image = icon
			iv.imageScaling = .scaleProportionallyUpOrDown
			tileView.addSubview(iv)
		}
		content.addSubview(tileView)

		// Two-line text stack
		let textX = pad + tile + gap
		let textW = width - textX - pad
		let textH = titleFit.height + textGap + subtitleFit.height
		let textY = tileY + (tile - textH) / 2

		if !subtitle.isEmpty {
			subtitleLabel.frame = NSRect(x: textX, y: textY, width: textW, height: subtitleFit.height)
			content.addSubview(subtitleLabel)
		}
		titleLabel.frame = NSRect(
			x: textX,
			y: textY + (subtitle.isEmpty ? 0 : subtitleFit.height + textGap),
			width: textW, height: titleFit.height)
		content.addSubview(titleLabel)

		// --- Window ---
		let top = screen.frame.maxY
		let wx = screen.frame.midX - width / 2
		let hidden = NSRect(x: wx, y: top + 8, width: width, height: height)
		let shown = NSRect(x: wx, y: top - height + clip, width: width, height: height)

		let window = NSWindow(contentRect: hidden, styleMask: .borderless, backing: .buffered, defer: false)
		window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false
		window.ignoresMouseEvents = true
		window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
		window.contentView = content

		NSSound(named: NSSound.Name("Glass"))?.play()
		window.orderFrontRegardless()

		NSAnimationContext.runAnimationGroup({ ctx in
			ctx.duration = 0.6
			ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.5, 1) // slight overshoot
			window.animator().setFrame(shown, display: true)
		}) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
				NSAnimationContext.runAnimationGroup({ ctx in
					ctx.duration = 0.4
					ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
					window.animator().setFrame(hidden, display: true)
					window.animator().alphaValue = 0
				}) {
					app.terminate(nil)
				}
			}
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 6) { app.terminate(nil) } // safety net

		app.run()
	}
}
