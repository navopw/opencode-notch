// notch — Dynamic Island-style drop-down notification for macOS.
// Build: bun run build:swift (compiles the helper and assembles swift/notch.app)
// Usage: open -g -n ./swift/notch.app --args "Project" "Session" 3 42 10 "branch" "42"
// The app bundle carries LSUIElement=true so the process is born a background
// UI element: it never activates and never steals focus from the current app.

import Cocoa
import QuartzCore

// MARK: - Motion

/// Unit-step response of a damped spring, matching SwiftUI's
/// `Animation.spring(response:dampingFraction:)`: `response` is the natural
/// period (2π/ω) and `damping` is the damping ratio ζ. Under-damped springs
/// (ζ < 1) shoot past 1 before settling back, and that overshoot is what makes
/// the island feel rubbery rather than merely fast.
struct Spring {
	let response: Double
	let damping: Double

	/// Progress from 0 towards 1, briefly exceeding it when under-damped.
	func progress(at t: Double) -> Double {
		guard t > 0 else { return 0 }
		let omega = 2 * Double.pi / response
		let zeta = min(max(damping, 0), 1)
		let decay = exp(-zeta * omega * t)
		guard zeta < 0.9999 else {
			return 1 - decay * (1 + omega * t) // critically damped: no overshoot
		}
		let ratio = (1 - zeta * zeta).squareRoot()
		let damped = omega * ratio
		return 1 - decay * (cos(damped * t) + zeta / ratio * sin(damped * t))
	}
}

/// Calls a closure once per display refresh until it reports completion.
///
/// The island's geometry is recomputed every frame rather than handed to Core
/// Animation because the silhouette morphs — width, height and both corner
/// radii move together — and a spring has to be free to overshoot its target
/// value. Neither survives a `CABasicAnimation` on a single property.
final class FrameDriver: NSObject {
	private let step: (Double) -> Bool
	private var startedAt: CFTimeInterval = 0
	private var link: AnyObject?
	private var timer: Timer?

	init(step: @escaping (Double) -> Bool) {
		self.step = step
		super.init()
	}

	/// `view` only selects which display to sync to; it is not retained.
	func start(in view: NSView) {
		startedAt = CACurrentMediaTime()
		if #available(macOS 14.0, *) {
			let link = view.displayLink(target: self, selector: #selector(tick))
			link.add(to: .main, forMode: .common)
			self.link = link
		} else {
			let timer = Timer(
				timeInterval: 1.0 / 120, target: self, selector: #selector(tick), userInfo: nil,
				repeats: true)
			RunLoop.main.add(timer, forMode: .common)
			self.timer = timer
		}
	}

	func stop() {
		if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
		link = nil
		timer?.invalidate()
		timer = nil
	}

	@objc private func tick() {
		if !step(CACurrentMediaTime() - startedAt) { stop() }
	}
}

/// Ease-out cubic over a 0...1 clamped input.
func easeOut(_ x: Double) -> Double {
	let c = min(max(x, 0), 1)
	return 1 - pow(1 - c, 3)
}

// MARK: - Views

/// A view whose backing layer *is* the island silhouette. Filling a path in the
/// render server (instead of `draw(_:)`) keeps a per-frame shape morph on the
/// GPU and hands us `shadowPath` for free.
final class ShapeView: NSView {
	override func makeBackingLayer() -> CALayer {
		let shape = CAShapeLayer()
		// Fully opaque: the notch is a physical cutout, so anything translucent
		// reads lighter than it and breaks the illusion of one continuous shape.
		shape.fillColor = NSColor.black.cgColor
		shape.shadowColor = NSColor.black.cgColor
		shape.shadowOpacity = 0.35
		shape.shadowRadius = 10
		shape.shadowOffset = CGSize(width: 0, height: -4)
		return shape
	}

	var shape: CAShapeLayer { layer as! CAShapeLayer }
}

/// The window's content view: an island that grows out of the notch.
///
/// The window itself never moves. `render(...)` is the only thing that changes
/// the island's geometry — it rebuilds the silhouette, the mask that clips the
/// content to it, and the content's own scale and fade in one pass, so a single
/// spring drives the whole shape and everything stretches in lockstep.
final class IslandView: NSView {
	var onDismiss: (() -> Void)?

	/// Slack around the card, for the spring's overshoot and the drop shadow.
	static let slack: CGFloat = 24

	/// Settled radius of the concave top fillets. They flare *outwards* from the
	/// card's body, so the silhouette is this much wider than the content on
	/// either side — carving them out of the body instead would eat into the
	/// card's own horizontal padding.
	static let fillet: CGFloat = 13

	/// Total width of the silhouette for a card of `cardWidth`.
	static func islandWidth(cardWidth: CGFloat, notched: Bool) -> CGFloat {
		cardWidth + (notched ? fillet * 2 : 0)
	}

	/// Concave fillets blend the card's top edge into the narrower notch above
	/// it, so the two black shapes read as one. Without a notch the card is a
	/// free-floating rounded rectangle instead.
	private let notched: Bool
	private let shapeView = ShapeView()
	private let clipView = NSView()
	private let contentMask = CAShapeLayer()
	/// Where the card's own subviews live. Scaled and faded as a unit.
	let card = NSView()

	init(frame: NSRect, cardSize: NSSize, notched: Bool) {
		self.notched = notched
		super.init(frame: frame)
		wantsLayer = true

		shapeView.frame = bounds
		shapeView.wantsLayer = true
		addSubview(shapeView)

		// Inset by the fillet so the card's body — and therefore its padding —
		// keeps the width it was laid out for, with the fillets flaring outside.
		let slack = IslandView.slack + (notched ? IslandView.fillet : 0)
		clipView.frame = NSRect(origin: NSPoint(x: slack, y: IslandView.slack), size: cardSize)
		clipView.wantsLayer = true
		contentMask.frame = NSRect(origin: .zero, size: cardSize)
		clipView.layer?.mask = contentMask
		addSubview(clipView)

		card.frame = NSRect(origin: .zero, size: cardSize)
		card.wantsLayer = true
		clipView.addSubview(card)
	}

	required init?(coder: NSCoder) { fatalError("not supported") }

	override func hitTest(_ point: NSPoint) -> NSView? { self }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func mouseDown(with event: NSEvent) { onDismiss?() }

	/// - Parameters:
	///   - shape: 0 = collapsed to `startWidth` and no height, 1 = fully open.
	///     May exceed 1 while the spring overshoots.
	///   - content: 0 = hidden, 1 = settled. Deliberately lags `shape`.
	///   - startWidth: the width the island collapses to — the notch's own.
	///   - fade: opacity of the silhouette. Stays 1 under a real notch, where
	///     the collapsed island is hidden behind the housing anyway.
	func render(shape: Double, content: Double, startWidth: CGFloat, fade: Double) {
		let cardSize = card.frame.size
		let s = CGFloat(shape)
		let full = IslandView.islandWidth(cardWidth: cardSize.width, notched: notched)
		let w = startWidth + (full - startWidth) * s
		let h = cardSize.height * s
		let rect = CGRect(x: bounds.midX - w / 2, y: bounds.maxY - h, width: w, height: h)

		// Both radii open up with the island, the way the Dynamic Island's
		// corners relax as it expands. Clamped so the path stays well-formed
		// while the island is still a sliver.
		let topR = notched ? max(0, min(6 + (IslandView.fillet - 6) * s, h / 2, w / 4)) : 0
		let bottomLimit = notched ? min(h - topR, (w - 2 * topR) / 2) : min(h / 2, w / 2)
		let botR = max(0, min(14 + 12 * s, bottomLimit))
		let path = IslandView.silhouette(
			in: rect, topRadius: topR, bottomRadius: botR, notched: notched)

		// The content slides up out of its own top edge as it fades in, so it
		// looks poured into the island rather than revealed behind it.
		let scaleY = 0.72 + 0.28 * CGFloat(content)
		let scaleX = 0.94 + 0.06 * CGFloat(content)
		var transform = CATransform3DMakeTranslation(0, cardSize.height / 2 * (1 - scaleY), 0)
		transform = CATransform3DScale(transform, scaleX, scaleY, 1)
		var toCard = CGAffineTransform(
			translationX: -clipView.frame.minX, y: -clipView.frame.minY)

		CATransaction.begin()
		CATransaction.setDisableActions(true) // per-frame values, never re-animated
		shapeView.shape.path = path
		shapeView.shape.shadowPath = path
		shapeView.shape.opacity = Float(min(max(fade, 0), 1))
		contentMask.path = path.copy(using: &toCard)
		card.layer?.transform = transform
		card.layer?.opacity = Float(min(max(content * 1.4, 0), 1))
		CATransaction.commit()
	}

	/// Dynamic Island silhouette: a full-width top edge that curves *inward* to
	/// meet the body, so the card blends into the notch above it instead of
	/// butting against it.
	private static func silhouette(
		in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat, notched: Bool
	) -> CGPath {
		let path = CGMutablePath()
		guard rect.width > 0, rect.height > 0 else { return path }
		guard notched, topRadius > 0 else {
			path.addRoundedRect(in: rect, cornerWidth: bottomRadius, cornerHeight: bottomRadius)
			return path
		}
		let left = rect.minX + topRadius
		let right = rect.maxX - topRadius
		path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
		path.addQuadCurve(
			to: CGPoint(x: left, y: rect.maxY - topRadius),
			control: CGPoint(x: left, y: rect.maxY))
		path.addLine(to: CGPoint(x: left, y: rect.minY + bottomRadius))
		path.addQuadCurve(
			to: CGPoint(x: left + bottomRadius, y: rect.minY),
			control: CGPoint(x: left, y: rect.minY))
		path.addLine(to: CGPoint(x: right - bottomRadius, y: rect.minY))
		path.addQuadCurve(
			to: CGPoint(x: right, y: rect.minY + bottomRadius),
			control: CGPoint(x: right, y: rect.minY))
		path.addLine(to: CGPoint(x: right, y: rect.maxY - topRadius))
		path.addQuadCurve(
			to: CGPoint(x: rect.maxX, y: rect.maxY),
			control: CGPoint(x: right, y: rect.maxY))
		path.closeSubpath()
		return path
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
		let branch = args.count > 6 ? args[6] : ""
		let pr = args.count > 7 ? args[7] : ""
		let hasMeta = !branch.isEmpty

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(0) }

		// Top safe area. The camera housing is a physical cutout with no pixels behind
		// it, and the menu bar owns the strip beside it — anything drawn up there is
		// either invisible or painted over the menu bar. On notched Macs
		// safeAreaInsets.top is the notch height; elsewhere fall back to the menu bar
		// height (and to the status bar thickness when the menu bar auto-hides), so the
		// card always starts below whatever the system owns at the top of this screen.
		let hasNotch = screen.safeAreaInsets.top > 0
		let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
		let topInset =
			hasNotch
			? screen.safeAreaInsets.top
			: (menuBar > 0 ? menuBar : NSStatusBar.system.thickness)

		// The width the island grows out of and collapses back into. The areas
		// flanking the notch give its exact width; without a notch, pick a
		// pill-sized sliver so the card still blooms from the menu bar.
		let notchWidth: CGFloat = {
			guard hasNotch,
				let left = screen.auxiliaryTopLeftArea,
				let right = screen.auxiliaryTopRightArea
			else { return hasNotch ? 190 : 200 }
			return screen.frame.width - left.width - right.width
		}()

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

		// Meta line: branch symbol + branch name, plus the linked PR if any.
		let meta = NSMutableAttributedString()
		if hasMeta {
			if let sym = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")?
				.withSymbolConfiguration(
					NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
						.applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.62, alpha: 1)]))
				)
			{
				let attach = NSTextAttachment()
				attach.image = sym
				meta.append(NSAttributedString(attachment: attach))
			}
			let style: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11, weight: .medium),
				.foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
			]
			meta.append(NSAttributedString(string: " \(branch)", attributes: style))
			if !pr.isEmpty {
				meta.append(NSAttributedString(string: "  ·  PR #\(pr)", attributes: style))
			}
		}
		let metaLabel = NSTextField(labelWithAttributedString: meta)
		metaLabel.lineBreakMode = .byTruncatingTail
		metaLabel.maximumNumberOfLines = 1

		let huge = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		let titleFit = titleLabel.sizeThatFits(huge)
		let subtitleFit = subtitle.isEmpty ? NSSize.zero : subtitleLabel.sizeThatFits(huge)
		let additionsFit = hasChanges ? additionsLabel.sizeThatFits(huge) : NSSize.zero
		let deletionsFit = hasChanges ? deletionsLabel.sizeThatFits(huge) : NSSize.zero
		let metaFit = hasMeta ? metaLabel.sizeThatFits(huge) : NSSize.zero

		let pad: CGFloat = 20
		let tile: CGFloat = 48 // "album art" square
		let gap: CGFloat = 14
		let textGap: CGFloat = 3
		let statGap: CGFloat = 8
		let titleStatGap: CGFloat = 16
		let statsWidth = hasChanges ? additionsFit.width + statGap + deletionsFit.width : 0
		let titleRowWidth = titleFit.width + (hasChanges ? titleStatGap + statsWidth : 0)

		// Width hugs the content like the Dynamic Island, clamped.
		var width = pad + tile + gap + max(titleRowWidth, subtitleFit.width, metaFit.width) + pad
		width = max(340, min(560, width))
		let height: CGFloat = 92
		// How far the card's top edge crosses the safe-area boundary. Under a notch it
		// tucks 2pt behind the housing's bottom edge so no hairline seam separates the
		// two black shapes; without a notch it hangs 8pt clear of the menu bar as a
		// free-floating card.
		let overlap: CGFloat = hasNotch ? 2 : -8
		let clip = max(overlap, 0) // part of the card hidden behind the notch

		let visibleH = height - clip
		let tileY = (visibleH - tile) / 2

		// --- Window ---
		// The window is fixed: it sits where the fully open card belongs, padded
		// with slack for the spring's overshoot and the shadow. Only the island
		// inside it animates, which keeps the whole morph on the render server —
		// animating the window frame instead would drive it from the main thread
		// and could never overshoot past the notch.
		//
		// The silhouette is wider than the card it wraps, because the top fillets
		// flare outwards from the body rather than being carved out of it.
		let slack = IslandView.slack
		let safeTop = screen.frame.maxY - topInset
		let islandWidth = IslandView.islandWidth(cardWidth: width, notched: hasNotch)
		let islandOrigin = NSPoint(
			x: screen.frame.midX - islandWidth / 2, y: safeTop + overlap - height)
		let windowRect = NSRect(
			x: islandOrigin.x - slack, y: islandOrigin.y - slack,
			width: islandWidth + slack * 2, height: height + slack)

		let island = IslandView(
			frame: NSRect(origin: .zero, size: windowRect.size),
			cardSize: NSSize(width: width, height: height),
			notched: hasNotch)
		let content = island.card

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

		// Text stack: meta (branch/PR) at the bottom, subtitle, title on top.
		let textX = pad + tile + gap
		let textW = width - textX - pad
		let textH =
			titleFit.height
			+ (subtitle.isEmpty ? 0 : textGap + subtitleFit.height)
			+ (hasMeta ? textGap + metaFit.height : 0)
		let textY = tileY + (tile - textH) / 2

		var stackY = textY
		if hasMeta {
			metaLabel.frame = NSRect(x: textX, y: stackY, width: textW, height: metaFit.height)
			content.addSubview(metaLabel)
			stackY += metaFit.height + textGap
		}
		if !subtitle.isEmpty {
			subtitleLabel.frame = NSRect(x: textX, y: stackY, width: textW, height: subtitleFit.height)
			content.addSubview(subtitleLabel)
			stackY += subtitleFit.height + textGap
		}
		let titleY = stackY
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

		let window = NonActivatingPanel(
			contentRect: windowRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
			defer: false)
		window.hidesOnDeactivate = false
		window.isFloatingPanel = true
		window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false
		window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
		window.contentView = island

		// --- Animation ---
		// Opening springs; closing does not. An under-damped open makes the card
		// stretch past its size and snap back, which is the whole character of
		// the Dynamic Island. Bouncing on the way out just looks indecisive, so
		// the close is critically damped — the same split DynamicNotchKit and
		// boring.notch both settled on.
		let startWidth = min(notchWidth, islandWidth)
		let open = Spring(response: 0.42, damping: hasNotch ? 0.74 : 0.9)
		let openDuration = 0.7
		let close = Spring(response: 0.34, damping: 1)
		let closeDuration = 0.42
		let dwell = 2.8

		// Holds the collapse driver for its lifetime, and doubles as the guard
		// against dismissing twice (a click landing during the auto-dismiss).
		var closing: FrameDriver?

		let opening = FrameDriver { t in
			guard t < openDuration else {
				island.render(shape: 1, content: 1, startWidth: startWidth, fade: 1)
				return false
			}
			island.render(
				shape: open.progress(at: t),
				// The content trails the shape: the island opens first, then the
				// content settles into the room it made.
				content: easeOut((t - 0.09) / 0.30),
				startWidth: startWidth,
				fade: hasNotch ? 1 : easeOut(t / 0.12))
			return true
		}

		func dismiss() {
			guard closing == nil else { return }
			opening.stop()
			let driver = FrameDriver { t in
				guard t < closeDuration else {
					island.render(shape: 0, content: 0, startWidth: startWidth, fade: 0)
					app.terminate(nil)
					return false
				}
				island.render(
					shape: 1 - close.progress(at: t),
					// Content clears out ahead of the shape, so the island never
					// closes over legible text.
					content: 1 - easeOut(t / 0.15),
					startWidth: startWidth,
					fade: hasNotch ? 1 : 1 - easeOut(t / 0.22))
				return true
			}
			closing = driver
			driver.start(in: island)
		}
		island.onDismiss = dismiss

		// Seed the collapsed state before the window is visible, so the card is
		// never shown at full size for a frame.
		island.render(shape: 0, content: 0, startWidth: startWidth, fade: 0)
		window.orderFrontRegardless()
		// Insurance: if the system activated us anyway, hand focus straight back.
		if app.isActive { app.deactivate() }

		opening.start(in: island)
		DispatchQueue.main.asyncAfter(deadline: .now() + openDuration + dwell) { dismiss() }
		DispatchQueue.main.asyncAfter(deadline: .now() + 6) { app.terminate(nil) } // safety net

		app.run()
	}
}
