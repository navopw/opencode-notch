// notch — Dynamic Island-style drop-down notification for macOS.
// Build: bun run build:swift (compiles the helper and assembles swift/notch.app)
// Usage: open -g -n ./swift/notch.app --args "Project" "Session" 3 42 10
// The app bundle carries LSUIElement=true so the process is born a background
// UI element: it never activates and never steals focus from the current app.

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

// A panel that never becomes key/main and never activates the app,
// so showing the pill doesn't steal focus from the user's current app.
final class NonActivatingPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

@main
@MainActor
enum NotchApp {
	static func main() {
		let args = CommandLine.arguments
		let title = args.count > 1 ? args[1] : "opencode"
		let subtitle = args.count > 2 ? args[2] : ""
		let files = max(0, args.count > 3 ? Int(args[3]) ?? 0 : 0)
		let additions = max(0, args.count > 4 ? Int(args[4]) ?? 0 : 0)
		let deletions = max(0, args.count > 5 ? Int(args[5]) ?? 0 : 0)
		let hasChanges = files > 0 || additions > 0 || deletions > 0

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(0) }

		// --- Content ---
		let icon = NSImage(systemSymbolName: "ellipsis.message.fill", accessibilityDescription: "Response ready")?
			.withSymbolConfiguration(
				NSImage.SymbolConfiguration(pointSize: 19, weight: .bold)
					.applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
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

		let additionsLabel = NSTextField(labelWithString: "+\(additions)")
		additionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		additionsLabel.textColor = .systemGreen

		let deletionsLabel = NSTextField(labelWithString: "−\(deletions)")
		deletionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		deletionsLabel.textColor = .systemRed

		let huge = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		let titleFit = titleLabel.sizeThatFits(huge)
		let subtitleFit = subtitle.isEmpty ? NSSize.zero : subtitleLabel.sizeThatFits(huge)
		let additionsFit = hasChanges ? additionsLabel.sizeThatFits(huge) : NSSize.zero
		let deletionsFit = hasChanges ? deletionsLabel.sizeThatFits(huge) : NSSize.zero

		let pad: CGFloat = 20
		let tile: CGFloat = 48 // "album art" square
		let gap: CGFloat = 14
		let textGap: CGFloat = 3
		let statGap: CGFloat = 8
		let titleStatGap: CGFloat = 16
		let statsWidth = hasChanges ? additionsFit.width + statGap + deletionsFit.width : 0
		let titleRowWidth = titleFit.width + (hasChanges ? titleStatGap + statsWidth : 0)

		// Width hugs the content like the Dynamic Island, clamped.
		var width = pad + tile + gap + max(titleRowWidth, subtitleFit.width) + pad
		width = max(340, min(560, width))
		let height: CGFloat = 92
		let clip: CGFloat = 6 // top stays hidden above the screen edge, merges with the notch

		let visibleH = height - clip
		let tileY = (visibleH - tile) / 2

		let content = IslandView(frame: NSRect(x: 0, y: 0, width: width, height: height))

		// Summary tile
		let tileView = RoundedTile(frame: NSRect(x: pad, y: tileY, width: tile, height: tile))
		if hasChanges {
			let countLabel = NSTextField(labelWithString: "\(files)")
			countLabel.font = .monospacedDigitSystemFont(
				ofSize: files > 999 ? 14 : 18, weight: .semibold)
			countLabel.textColor = .white
			countLabel.alignment = .center
			countLabel.frame = NSRect(x: 2, y: 20, width: tile - 4, height: 21)
			tileView.addSubview(countLabel)

			let fileLabel = NSTextField(labelWithString: files == 1 ? "FILE" : "FILES")
			fileLabel.font = .systemFont(ofSize: 8, weight: .semibold)
			fileLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
			fileLabel.alignment = .center
			fileLabel.frame = NSRect(x: 2, y: 8, width: tile - 4, height: 10)
			tileView.addSubview(fileLabel)
		} else if let icon {
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
		let titleY = textY + (subtitle.isEmpty ? 0 : subtitleFit.height + textGap)

		if !subtitle.isEmpty {
			subtitleLabel.frame = NSRect(x: textX, y: textY, width: textW, height: subtitleFit.height)
			content.addSubview(subtitleLabel)
		}
		let titleWidth = textW - (hasChanges ? titleStatGap + statsWidth : 0)
		titleLabel.frame = NSRect(x: textX, y: titleY, width: titleWidth, height: titleFit.height)
		content.addSubview(titleLabel)

		if hasChanges {
			let statsHeight = max(additionsFit.height, deletionsFit.height)
			let statsY = titleY + (titleFit.height - statsHeight) / 2
			let statsX = textX + textW - statsWidth
			additionsLabel.frame = NSRect(
				x: statsX, y: statsY, width: additionsFit.width, height: additionsFit.height)
			deletionsLabel.frame = NSRect(
				x: statsX + additionsFit.width + statGap,
				y: statsY,
				width: deletionsFit.width,
				height: deletionsFit.height)
			content.addSubview(additionsLabel)
			content.addSubview(deletionsLabel)
		}

		// --- Window ---
		let top = screen.frame.maxY
		let wx = screen.frame.midX - width / 2
		let hidden = NSRect(x: wx, y: top + 8, width: width, height: height)
		let shown = NSRect(x: wx, y: top - height + clip, width: width, height: height)

		let window = NonActivatingPanel(
			contentRect: hidden, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
			defer: false)
		window.hidesOnDeactivate = false
		window.isFloatingPanel = true
		window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false
		window.ignoresMouseEvents = true
		window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
		window.contentView = content

		NSSound(named: NSSound.Name("Glass"))?.play()
		window.orderFrontRegardless()
		// Insurance: if the system activated us anyway, hand focus straight back.
		if app.isActive { app.deactivate() }

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
