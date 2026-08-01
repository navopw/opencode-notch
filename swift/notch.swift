// notch — Dynamic Island-style drop-down notifications for OpenCode.
// Build: bun run build:swift (compiles the helper and assembles swift/notch.app)
//
// Modes:
//   notch "Project" "Session" 3 42 10 "branch" "42"    one-shot card (legacy)
//   notch --serve                                       NDJSON protocol on stdio
//   notch --serve --socket /path/notch.sock             NDJSON Unix-socket daemon
//
// Protocol (one JSON object per line, both directions; unknown fields and
// unknown commands are ignored so mismatched versions degrade, not deadlock):
//   in:  {"cmd":"show","id":"idle:ses_x","kind":"idle","dwell":2.8,"timeout":60,
//         "title":"project","subtitle":"Session title","branch":"main","pr":"7",
//         "files":3,"additions":42,"deletions":10}
//        {"cmd":"show","id":"perm:per_x","kind":"permission","dwell":0,"timeout":120,
//         "title":"bash","subtitle":"rm -rf build","mono":true,"meta":"Session title",
//         "actions":[{"id":"once","label":"Allow","style":"primary"},
//                    {"id":"always","label":"Always"},
//                    {"id":"reject","label":"Deny","style":"danger"}]}
//        {"cmd":"show","id":"error:ses_x","kind":"error","dwell":5,"timeout":60,
//         "title":"project","subtitle":"Provider rejected the request",
//         "meta":"Session title"}
//        {"cmd":"update", ...}   like show, but a no-op if the id is gone
//        {"cmd":"dismiss","id":"perm:per_x"}
//        {"cmd":"clear"}
//   out: {"event":"ready","version":"0.6.0"}
//        {"event":"action","id":"perm:per_x","action":"once"}   (card retracts itself)
//        {"event":"dismissed","id":"idle:ses_x","reason":"timeout|user|replaced"}
//
// `dwell` is seconds before auto-retract (0 = sticky); hovering pauses it.
// `timeout` is a hard upper bound that ignores hover (0 = none). A `show` with
// an id already on screen replaces that card in place without re-animating.
// Plugin-initiated removals (`dismiss`, `clear`) are not echoed back.
//
// The app bundle carries LSUIElement=true so the process is born a background
// UI element: it never activates and never steals focus from the current app.
// In stdio mode EOF on stdin retracts everything and exits — the helper's
// lifetime is its parent's. In socket mode the daemon exits ~10s after its
// last client disconnects, and unlinks its socket on the way out.

import Cocoa
import QuartzCore

// MARK: - Motion

/// A spring-integrated scalar that can be retargeted mid-flight: the stack
/// grows while the island is still opening, so animations must depart from
/// *current* position and velocity, not from a captured start. Semi-implicit
/// Euler with substeps; `response` is the natural period (2π/ω) and `damping`
/// the damping ratio ζ — under-damped values overshoot, which is the whole
/// character of the Dynamic Island.
struct AnimatedValue {
	var value: Double
	var velocity: Double = 0
	private(set) var target: Double
	var response: Double
	var damping: Double

	init(_ value: Double, response: Double = 0.42, damping: Double = 0.85) {
		self.value = value
		self.target = value
		self.response = response
		self.damping = damping
	}

	mutating func retarget(_ newTarget: Double, response: Double? = nil, damping: Double? = nil) {
		if let response { self.response = response }
		if let damping { self.damping = damping }
		target = newTarget
	}

	mutating func snap(to newTarget: Double) {
		target = newTarget
		value = newTarget
		velocity = 0
	}

	var settled: Bool { velocity == 0 && value == target }

	/// Advance by `dt`; returns true while still moving.
	mutating func step(_ dt: Double) -> Bool {
		if settled { return false }
		var remaining = min(dt, 1.0 / 15) // clamp stalls (debugger, sleep) to a sane hop
		let omega = 2 * Double.pi / max(response, 0.05)
		while remaining > 0 {
			let h = min(remaining, 1.0 / 240)
			remaining -= h
			let accel = -omega * omega * (value - target) - 2 * damping * omega * velocity
			velocity += accel * h
			value += velocity * h
		}
		if abs(value - target) < 0.05, abs(velocity) < 1 {
			value = target
			velocity = 0
			return false
		}
		return true
	}
}

/// Calls a closure once per display refresh until it reports completion.
/// Restartable: the controller keeps one and kicks it whenever geometry moves.
final class FrameDriver: NSObject {
	private let step: (Double) -> Bool
	private var lastTime: CFTimeInterval = 0
	private var link: AnyObject?
	private var timer: Timer?
	private(set) var running = false

	init(step: @escaping (Double) -> Bool) {
		self.step = step
		super.init()
	}

	/// `view` only selects which display to sync to; it is not retained.
	func start(in view: NSView) {
		guard !running else { return }
		running = true
		lastTime = CACurrentMediaTime()
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
		running = false
		if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
		link = nil
		timer?.invalidate()
		timer = nil
	}

	@objc private func tick() {
		let now = CACurrentMediaTime()
		let dt = now - lastTime
		lastTime = now
		if !step(dt) { stop() }
	}
}

/// Ease-out cubic over a 0...1 clamped input.
func easeOut(_ x: Double) -> Double {
	let c = min(max(x, 0), 1)
	return 1 - pow(1 - c, 3)
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

// MARK: - Wire protocol

struct WireAction: Decodable {
	let id: String
	let label: String
	let style: String?
}

struct WireCommand: Decodable {
	let cmd: String
	let id: String?
	let kind: String?
	let dwell: Double?
	let timeout: Double?
	let title: String?
	let subtitle: String?
	let meta: String?
	let mono: Bool?
	let branch: String?
	let pr: String?
	let files: Int?
	let additions: Int?
	let deletions: Int?
	let actions: [WireAction]?
}

/// One card's model, built from a `show` command or from legacy argv.
struct NotchItem {
	var id: String
	var kind: String
	var dwell: Double
	var timeout: Double
	var title: String
	var subtitle: String
	var meta: String
	var mono: Bool
	var branch: String
	var pr: String
	var files: Int
	var additions: Int
	var deletions: Int
	var actions: [WireAction]

	var isPermission: Bool { kind == "permission" }
	// Errors carry no buttons and stack like idle cards; only the glyph differs.
	var isError: Bool { kind == "error" }

	init(command: WireCommand) {
		id = command.id ?? ""
		kind = command.kind ?? "idle"
		dwell = command.dwell ?? 2.8
		timeout = command.timeout ?? 0
		title = command.title ?? ""
		subtitle = command.subtitle ?? ""
		meta = command.meta ?? ""
		mono = command.mono ?? false
		branch = command.branch ?? ""
		pr = command.pr ?? ""
		files = max(0, command.files ?? 0)
		additions = max(0, command.additions ?? 0)
		deletions = max(0, command.deletions ?? 0)
		actions = command.actions ?? []
	}

	init(argv args: [String]) {
		id = "argv"
		kind = "idle"
		dwell = 2.8
		timeout = 45
		title = args.count > 1 ? args[1] : "opencode"
		subtitle = args.count > 2 ? args[2] : ""
		meta = ""
		mono = false
		files = max(0, args.count > 3 ? Int(args[3]) ?? 0 : 0)
		additions = max(0, args.count > 4 ? Int(args[4]) ?? 0 : 0)
		deletions = max(0, args.count > 5 ? Int(args[5]) ?? 0 : 0)
		branch = args.count > 6 ? args[6] : ""
		pr = args.count > 7 ? args[7] : ""
		actions = []
	}
}

// MARK: - IO

func logError(_ message: String) {
	FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Serialized writes to a file descriptor; short writes retried, errors
/// swallowed (a dead pipe just means nobody is listening anymore).
final class FDWriter {
	private let fd: Int32
	private let queue = DispatchQueue(label: "notch.write")

	init(fd: Int32) { self.fd = fd }

	func writeLine(_ data: Data) {
		var payload = data
		payload.append(0x0A)
		queue.async { [fd] in
			payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
				guard var p = raw.baseAddress else { return }
				var n = raw.count
				while n > 0 {
					let w = write(fd, p, n)
					if w > 0 {
						p += w
						n -= w
					} else if errno != EINTR {
						return
					}
				}
			}
		}
	}
}

/// Reads newline-delimited frames off a file descriptor on a background
/// queue and delivers them on the main queue. EOF is the shutdown signal —
/// in stdio mode this is what makes the helper's lifetime its parent's.
final class LineReader {
	private let source: DispatchSourceRead
	private var buffer = Data()

	init(fd: Int32, onLine: @escaping (String) -> Void, onEOF: @escaping () -> Void) {
		source = DispatchSource.makeReadSource(
			fileDescriptor: fd, queue: DispatchQueue(label: "notch.read"))
		source.setEventHandler { [source] in
			var chunk = [UInt8](repeating: 0, count: 65536)
			let n = read(fd, &chunk, chunk.count)
			if n > 0 {
				self.buffer.append(contentsOf: chunk[0..<n])
				while let nl = self.buffer.firstIndex(of: 0x0A) {
					let lineData = self.buffer.prefix(upTo: nl)
					self.buffer = Data(self.buffer.suffix(from: self.buffer.index(after: nl)))
					if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
						DispatchQueue.main.async { onLine(line) }
					}
				}
			} else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
				source.cancel()
				DispatchQueue.main.async { onEOF() }
			}
		}
		source.resume()
	}

	func cancel() { source.cancel() }
}

/// One connected plugin. `id` scopes item keys so two OpenCode instances
/// can both show a card called "idle:ses_x" without colliding, and so a
/// disconnect can drop exactly that client's cards.
final class ClientRef {
	let id: Int
	private let writer: FDWriter?

	init(id: Int, writer: FDWriter?) {
		self.id = id
		self.writer = writer
	}

	func send(_ event: [String: Any]) {
		guard let writer,
			let data = try? JSONSerialization.data(withJSONObject: event)
		else { return }
		writer.writeLine(data)
	}
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

final class RoundedTile: NSView {
	override func draw(_ dirtyRect: NSRect) {
		NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
	}
}

/// A button that works on the first click inside a panel that never becomes
/// key: without both overrides the first click on an inactive app's panel is
/// eaten as a focus click instead of pressing the button.
class FirstClickButton: NSButton {
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override var needsPanelToBecomeKey: Bool { false }
}

/// Pill-shaped Allow/Always/Deny button for permission cards.
final class ActionButton: FirstClickButton {
	let actionID: String
	var onPress: ((String) -> Void)?

	init(action: WireAction) {
		actionID = action.id
		super.init(frame: .zero)
		isBordered = false
		wantsLayer = true
		layer?.cornerRadius = 14
		let background: NSColor
		switch action.style ?? "default" {
		case "primary": background = .systemBlue
		case "danger": background = NSColor.systemRed.withAlphaComponent(0.85)
		default: background = NSColor(calibratedWhite: 1, alpha: 0.16)
		}
		layer?.backgroundColor = background.cgColor
		let style = NSMutableParagraphStyle()
		style.alignment = .center
		attributedTitle = NSAttributedString(
			string: action.label,
			attributes: [
				.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
				.foregroundColor: NSColor.white,
				.paragraphStyle: style,
			])
		target = self
		self.action = #selector(pressed)
		let fit = attributedTitle.size()
		frame = NSRect(x: 0, y: 0, width: ceil(fit.width) + 28, height: 28)
	}

	required init?(coder: NSCoder) { fatalError("not supported") }

	@objc private func pressed() { onPress?(actionID) }
}

/// The hover-only × in a card's top-right corner. Replaces click-anywhere
/// dismissal: the card body is inert, this is the one explicit affordance.
final class CloseButton: FirstClickButton {
	var onPress: (() -> Void)?

	init() {
		super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
		isBordered = false
		wantsLayer = true
		layer?.cornerRadius = 9
		layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
		image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
			.withSymbolConfiguration(
				NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
					.applying(
						NSImage.SymbolConfiguration(paletteColors: [
							NSColor(calibratedWhite: 0.85, alpha: 1)
						])))
		imagePosition = .imageOnly
		alphaValue = 0
		target = self
		action = #selector(pressed)
	}

	required init?(coder: NSCoder) { fatalError("not supported") }

	@objc private func pressed() { onPress?() }
}

/// One card's subviews. Content is measured once at init to find the natural
/// width; `layout(width:)` re-flows it at the shared stack width, since every
/// card in the island renders at the width of the widest.
final class CardView: NSView {
	let item: NotchItem
	private(set) var naturalWidth: CGFloat = 340
	let cardHeight: CGFloat
	var onAction: ((String) -> Void)?
	var onClose: (() -> Void)?

	private let pad: CGFloat = 20
	private let tileSize: CGFloat = 48
	private let tileGap: CGFloat = 14
	private let textGap: CGFloat = 3
	private let statGap: CGFloat = 8
	private let titleStatGap: CGFloat = 16
	private let buttonRow: CGFloat = 40 // 28pt buttons + 12pt bottom inset

	private let tileView = RoundedTile()
	private let titleLabel: NSTextField
	private let subtitleLabel: NSTextField
	private let metaLabel: NSTextField
	private let additionsLabel: NSTextField
	private let deletionsLabel: NSTextField
	private var buttons: [ActionButton] = []
	private var closeButton: CloseButton?

	private let hasChanges: Bool
	private let hasMeta: Bool

	init(item: NotchItem) {
		self.item = item
		hasChanges = item.files > 0 || item.additions > 0 || item.deletions > 0
		cardHeight = 92 + (item.actions.isEmpty ? 0 : buttonRow)

		titleLabel = NSTextField(labelWithString: item.title)
		titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
		titleLabel.textColor = .white
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.maximumNumberOfLines = 1

		subtitleLabel = NSTextField(labelWithString: item.subtitle)
		// Permission subtitles carry a literal command; monospace keeps it legible
		// and middle truncation keeps both ends of a long command visible.
		subtitleLabel.font =
			item.mono
			? .monospacedSystemFont(ofSize: 12, weight: .regular)
			: .systemFont(ofSize: 13, weight: .regular)
		subtitleLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
		subtitleLabel.lineBreakMode = item.mono ? .byTruncatingMiddle : .byTruncatingTail
		subtitleLabel.maximumNumberOfLines = 1

		additionsLabel = NSTextField(labelWithString: "+\(item.additions)")
		additionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		additionsLabel.textColor = .systemGreen

		deletionsLabel = NSTextField(labelWithString: "−\(item.deletions)")
		deletionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		deletionsLabel.textColor = .systemRed

		// Meta line: plain text (permission cards show the session title), or
		// branch symbol + branch name plus the linked PR for idle cards.
		let meta = NSMutableAttributedString()
		let metaStyle: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 11, weight: .medium),
			.foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
		]
		if !item.meta.isEmpty {
			meta.append(NSAttributedString(string: item.meta, attributes: metaStyle))
		} else if !item.branch.isEmpty {
			if let sym = NSImage(
				systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")?
				.withSymbolConfiguration(
					NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
						.applying(
							NSImage.SymbolConfiguration(paletteColors: [
								NSColor(calibratedWhite: 0.62, alpha: 1)
							])))
			{
				let attach = NSTextAttachment()
				attach.image = sym
				meta.append(NSAttributedString(attachment: attach))
			}
			meta.append(NSAttributedString(string: " \(item.branch)", attributes: metaStyle))
			if !item.pr.isEmpty {
				meta.append(NSAttributedString(string: "  ·  PR #\(item.pr)", attributes: metaStyle))
			}
		}
		hasMeta = meta.length > 0
		metaLabel = NSTextField(labelWithAttributedString: meta)
		metaLabel.lineBreakMode = .byTruncatingTail
		metaLabel.maximumNumberOfLines = 1

		super.init(frame: NSRect(x: 0, y: 0, width: 340, height: cardHeight))
		wantsLayer = true

		// Tile: file count when a diff exists, otherwise a kind-specific glyph.
		if hasChanges {
			let countLabel = NSTextField(labelWithString: "\(item.files)")
			countLabel.font = .monospacedDigitSystemFont(
				ofSize: item.files > 999 ? 14 : 18, weight: .semibold)
			countLabel.textColor = .white
			countLabel.alignment = .center
			countLabel.frame = NSRect(x: 2, y: 20, width: tileSize - 4, height: 21)
			tileView.addSubview(countLabel)

			let fileLabel = NSTextField(labelWithString: item.files == 1 ? "FILE" : "FILES")
			fileLabel.font = .systemFont(ofSize: 8, weight: .semibold)
			fileLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
			fileLabel.alignment = .center
			fileLabel.frame = NSRect(x: 2, y: 8, width: tileSize - 4, height: 10)
			tileView.addSubview(fileLabel)
		} else {
			let symbol: String
			let color: NSColor
			if item.isPermission {
				symbol = "hand.raised.fill"
				color = .systemOrange
			} else if item.isError {
				symbol = "exclamationmark.triangle.fill"
				color = .systemRed
			} else {
				symbol = "ellipsis.message.fill"
				color = .systemBlue
			}
			if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: item.kind)?
				.withSymbolConfiguration(
					NSImage.SymbolConfiguration(pointSize: 19, weight: .bold)
						.applying(NSImage.SymbolConfiguration(paletteColors: [color])))
			{
				let iv = NSImageView(frame: NSRect(x: 13, y: 13, width: 22, height: 22))
				iv.image = icon
				iv.imageScaling = .scaleProportionallyUpOrDown
				tileView.addSubview(iv)
			}
		}
		addSubview(tileView)
		addSubview(titleLabel)
		if !item.subtitle.isEmpty { addSubview(subtitleLabel) }
		if hasMeta { addSubview(metaLabel) }
		if hasChanges {
			addSubview(additionsLabel)
			addSubview(deletionsLabel)
		}

		for action in item.actions {
			let button = ActionButton(action: action)
			button.onPress = { [weak self] id in self?.onAction?(id) }
			buttons.append(button)
			addSubview(button)
		}

		// Only cards without buttons get the ×: a permission card must not be
		// silently thrown away while a tool waits on its answer.
		if item.actions.isEmpty {
			let close = CloseButton()
			close.onPress = { [weak self] in self?.onClose?() }
			closeButton = close
			addSubview(close)
		}

		naturalWidth = measureNaturalWidth()
		layout(width: naturalWidth)
	}

	required init?(coder: NSCoder) { fatalError("not supported") }

	private func measureNaturalWidth() -> CGFloat {
		let huge = NSSize(
			width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		let titleFit = titleLabel.sizeThatFits(huge)
		let subtitleFit = item.subtitle.isEmpty ? NSSize.zero : subtitleLabel.sizeThatFits(huge)
		let metaFit = hasMeta ? metaLabel.sizeThatFits(huge) : NSSize.zero
		let statsWidth =
			hasChanges
			? additionsLabel.sizeThatFits(huge).width + statGap + deletionsLabel.sizeThatFits(huge).width
			: 0
		let titleRowWidth = titleFit.width + (hasChanges ? titleStatGap + statsWidth : 0)
		// Width hugs the content like the Dynamic Island, clamped. Permission
		// cards bias to the wider end so a long command stays readable.
		var width =
			pad + tileSize + tileGap + max(titleRowWidth, subtitleFit.width, metaFit.width) + pad
		if !buttons.isEmpty {
			let row = buttons.reduce(0) { $0 + $1.frame.width } + CGFloat(buttons.count - 1) * statGap
			width = max(width, pad + row + pad, 420)
		}
		return max(340, min(560, width))
	}

	/// Re-flow the content at the shared stack width. Cheap: only runs when
	/// stack membership changes, not per animation frame.
	func layout(width: CGFloat) {
		setFrameSize(NSSize(width: width, height: cardHeight))
		let huge = NSSize(
			width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		let titleFit = titleLabel.sizeThatFits(huge)
		let subtitleFit = item.subtitle.isEmpty ? NSSize.zero : subtitleLabel.sizeThatFits(huge)
		let metaFit = hasMeta ? metaLabel.sizeThatFits(huge) : NSSize.zero
		let additionsFit = hasChanges ? additionsLabel.sizeThatFits(huge) : NSSize.zero
		let deletionsFit = hasChanges ? deletionsLabel.sizeThatFits(huge) : NSSize.zero
		let statsWidth = hasChanges ? additionsFit.width + statGap + deletionsFit.width : 0

		// The 92pt content block sits at the top of the card; a button row, when
		// present, occupies the extra 40pt below it.
		let contentBottom = cardHeight - 92
		let tileY = contentBottom + (92 - tileSize) / 2
		tileView.frame = NSRect(x: pad, y: tileY, width: tileSize, height: tileSize)

		let textX = pad + tileSize + tileGap
		let textW = width - textX - pad
		let textH =
			titleFit.height
			+ (item.subtitle.isEmpty ? 0 : textGap + subtitleFit.height)
			+ (hasMeta ? textGap + metaFit.height : 0)
		var stackY = tileY + (tileSize - textH) / 2
		if hasMeta {
			metaLabel.frame = NSRect(x: textX, y: stackY, width: textW, height: metaFit.height)
			stackY += metaFit.height + textGap
		}
		if !item.subtitle.isEmpty {
			subtitleLabel.frame = NSRect(
				x: textX, y: stackY, width: textW, height: subtitleFit.height)
			stackY += subtitleFit.height + textGap
		}
		let titleWidth = textW - (hasChanges ? titleStatGap + statsWidth : 0)
		titleLabel.frame = NSRect(x: textX, y: stackY, width: titleWidth, height: titleFit.height)
		if hasChanges {
			let statsHeight = max(additionsFit.height, deletionsFit.height)
			let statsY = stackY + (titleFit.height - statsHeight) / 2
			let statsX = textX + textW - statsWidth
			additionsLabel.frame = NSRect(
				x: statsX, y: statsY, width: additionsFit.width, height: additionsFit.height)
			deletionsLabel.frame = NSRect(
				x: statsX + additionsFit.width + statGap, y: statsY,
				width: deletionsFit.width, height: deletionsFit.height)
		}

		var buttonX = width - pad
		for button in buttons.reversed() {
			buttonX -= button.frame.width
			button.setFrameOrigin(NSPoint(x: buttonX, y: 12))
			buttonX -= statGap
		}
		closeButton?.setFrameOrigin(NSPoint(x: width - 26, y: cardHeight - 26))
	}

	func setHovered(_ hovered: Bool) {
		guard let closeButton else { return }
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0.15
			closeButton.animator().alphaValue = hovered ? 1 : 0
		}
	}
}

/// The window's content view: an island that grows out of the notch and holds
/// a stack of cards. The window itself never moves; `render(...)` rebuilds the
/// silhouette, the mask that clips the cards to it, and the shadow in one pass.
final class IslandView: NSView {
	/// Slack around the island, for the spring's overshoot and the drop shadow.
	static let slack: CGFloat = 24

	/// Settled radius of the concave top fillets. They flare *outwards* from the
	/// card's body, so the silhouette is this much wider than the content on
	/// either side — carving them out of the body instead would eat into the
	/// card's own horizontal padding.
	static let fillet: CGFloat = 13

	static func islandWidth(cardWidth: CGFloat, notched: Bool) -> CGFloat {
		cardWidth + (notched ? fillet * 2 : 0)
	}

	/// Concave fillets blend the island's top edge into the narrower notch above
	/// it, so the two black shapes read as one. Without a notch the island is a
	/// free-floating rounded rectangle instead. Mutable: a resident helper can
	/// watch its cards migrate between a notched and a notchless display.
	var notched: Bool

	private let shapeView = ShapeView()
	private let clipView = NSView()
	private let contentMask = CAShapeLayer()
	/// Where the cards live, clipped to the silhouette.
	var cardContainer: NSView { clipView }
	/// The silhouette from the last render, in view coordinates — the single
	/// source of truth for hit-testing and the pointer poll.
	private(set) var currentPath: CGPath?

	init(frame: NSRect, notched: Bool) {
		self.notched = notched
		super.init(frame: frame)
		wantsLayer = true
		shapeView.frame = bounds
		shapeView.autoresizingMask = [.width, .height]
		shapeView.wantsLayer = true
		addSubview(shapeView)
		clipView.frame = bounds
		clipView.autoresizingMask = [.width, .height]
		clipView.wantsLayer = true
		clipView.layer?.mask = contentMask
		addSubview(clipView)
	}

	required init?(coder: NSCoder) { fatalError("not supported") }

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	/// Precise hit-testing: only the silhouette is interactive, so buttons and
	/// the × win inside it while the slack margin stays inert. (Clicks outside
	/// the island never even reach here — the controller flips the whole window
	/// to `ignoresMouseEvents` while the pointer is off the silhouette.)
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		guard let path = currentPath, path.contains(local) else { return nil }
		return super.hitTest(point)
	}

	func contains(_ localPoint: NSPoint) -> Bool {
		currentPath?.contains(localPoint) ?? false
	}

	/// Rebuild the silhouette for the current animated geometry.
	/// - Parameters:
	///   - width/height: island size; the island hangs from `bounds.maxY`.
	///   - progress: 0 = collapsed, 1 = settled; drives the corner radii the way
	///     the Dynamic Island's corners relax as it expands.
	///   - fade: silhouette opacity. Stays 1 under a real notch, where the
	///     collapsed island is hidden behind the housing anyway.
	func render(width: CGFloat, height: CGFloat, progress: Double, fade: Double) {
		let w = max(width, 2)
		let h = max(height, 0)
		let rect = CGRect(x: bounds.midX - w / 2, y: bounds.maxY - h, width: w, height: h)
		let s = CGFloat(clamp01(progress))
		let topR = notched ? max(0, min(6 + (IslandView.fillet - 6) * s, h / 2, w / 4)) : 0
		let bottomLimit = notched ? min(h - topR, (w - 2 * topR) / 2) : min(h / 2, w / 2)
		let botR = max(0, min(14 + 12 * s, bottomLimit))
		let path = IslandView.silhouette(
			in: rect, topRadius: topR, bottomRadius: botR, notched: notched)
		currentPath = path

		CATransaction.begin()
		CATransaction.setDisableActions(true) // per-frame values, never re-animated
		shapeView.shape.path = path
		shapeView.shape.shadowPath = path
		shapeView.shape.opacity = Float(clamp01(fade))
		contentMask.path = path
		CATransaction.commit()
	}

	/// Dynamic Island silhouette: a full-width top edge that curves *inward* to
	/// meet the body, so the island blends into the notch above it instead of
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

// A panel that never becomes key/main and never activates the app,
// so showing the island doesn't steal focus from the user's current app.
final class NonActivatingPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// One card on screen, with its animation and timing state.
private final class StackedItem {
	var item: NotchItem
	var card: CardView
	let key: String
	let clientID: Int
	weak var client: ClientRef?
	let seq: Int
	/// Distance from the island's top edge to this card's top edge. Springs so
	/// cards below a removed one translate up instead of jumping.
	var offset: AnimatedValue
	enum Phase {
		case entering(Double)
		case shown
		case leaving(Double)
	}
	var phase: Phase = .entering(0)
	/// Seconds of dwell left; only counts down while the pointer is off the
	/// island. Negative means sticky (dwell 0).
	var dwellRemaining: Double
	/// Hard deadline that ignores hover — a wedged card can't live forever.
	var timeoutAt: CFTimeInterval?
	let separator = CALayer()

	var isLeaving: Bool {
		if case .leaving = phase { return true }
		return false
	}

	init(item: NotchItem, card: CardView, key: String, client: ClientRef?, seq: Int, offset: Double) {
		self.item = item
		self.card = card
		self.key = key
		self.clientID = client?.id ?? 0
		self.client = client
		self.seq = seq
		self.offset = AnimatedValue(offset)
		dwellRemaining = item.dwell > 0 ? item.dwell : -1
		timeoutAt = item.timeout > 0 ? CACurrentMediaTime() + item.timeout : nil
		separator.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
	}

	func resetTimers() {
		dwellRemaining = item.dwell > 0 ? item.dwell : -1
		timeoutAt = item.timeout > 0 ? CACurrentMediaTime() + item.timeout : nil
	}
}

/// Owns the window, the island, the ordered stack, timers, and hover state.
/// The single place that decides target geometry and drives one FrameDriver
/// toward it.
final class NotchController {
	/// Called after the stack empties and the retract animation settles.
	/// One-shot mode terminates here; serve modes just idle with a hidden window.
	var onEmptyRetracted: (() -> Void)?

	private var items: [StackedItem] = []
	private var seqCounter = 0
	private var width = AnimatedValue(0)
	private var height = AnimatedValue(0)
	private var settledHeight: Double = 1
	private var stackWidth: CGFloat = 340
	private var hovered = false
	private var driver: FrameDriver?
	private var heartbeat: Timer?
	private var lastHeartbeat: CFTimeInterval = 0

	private var window: NonActivatingPanel?
	private var island: IslandView?
	private var hasNotch = false
	private var startWidth: CGFloat = 200

	private let separatorHeight: CGFloat = 1
	private let stackCap = 4
	private let hoverGrace = 1.2

	init() {
		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil,
			queue: .main
		) { [weak self] _ in self?.screenChanged() }
	}

	// MARK: Public commands (main thread)

	func show(_ item: NotchItem, client: ClientRef?, updateOnly: Bool = false) {
		guard !item.id.isEmpty else { return }
		let key = "\(client?.id ?? 0):\(item.id)"
		let existing = items.first(where: { $0.key == key && !$0.isLeaving })
		if updateOnly, existing == nil { return }
		if let existing {
			// Same id replaces in place without re-animating: swap the card's
			// content at the same slot and refresh its timers.
			let card = makeCard(for: item, stacked: existing)
			existing.card.removeFromSuperview()
			existing.item = item
			existing.card = card
			existing.resetTimers()
			if case .entering = existing.phase {} else { existing.phase = .shown }
			island?.cardContainer.addSubview(card)
			card.setHovered(hovered)
		} else {
			presentWindowIfNeeded()
			guard let island else { return }
			seqCounter += 1
			let stacked = StackedItem(
				item: item, card: CardView(item: item), key: key, client: client, seq: seqCounter,
				offset: 0)
			stacked.card.onAction = { [weak self, weak stacked] actionID in
				guard let stacked else { return }
				stacked.client?.send(["event": "action", "id": stacked.item.id, "action": actionID])
				self?.remove(stacked, notifyReason: nil)
			}
			stacked.card.onClose = { [weak self, weak stacked] in
				guard let stacked else { return }
				self?.remove(stacked, notifyReason: "user")
			}
			items.append(stacked)
			island.cardContainer.addSubview(stacked.card)
			island.cardContainer.layer?.addSublayer(stacked.separator)
			// Cap the stack; drop the oldest *idle* card on overflow — never a
			// pending permission.
			let visible = items.filter { !$0.isLeaving }
			if visible.count > stackCap,
				let oldest = visible.filter({ !$0.item.isPermission }).min(by: { $0.seq < $1.seq })
			{
				remove(oldest, notifyReason: "replaced")
			}
		}
		retarget()
	}

	func dismiss(id: String, client: ClientRef?) {
		let key = "\(client?.id ?? 0):\(id)"
		guard let stacked = items.first(where: { $0.key == key && !$0.isLeaving }) else { return }
		remove(stacked, notifyReason: nil)
	}

	func clear(client: ClientRef?) {
		for stacked in items where !stacked.isLeaving {
			if let client, stacked.clientID != client.id { continue }
			remove(stacked, notifyReason: nil)
		}
	}

	func dropClient(_ clientID: Int) {
		for stacked in items where stacked.clientID == clientID && !stacked.isLeaving {
			remove(stacked, notifyReason: nil)
		}
	}

	var isEmpty: Bool { items.isEmpty }

	// MARK: Internals

	private func makeCard(for item: NotchItem, stacked: StackedItem) -> CardView {
		let card = CardView(item: item)
		card.onAction = { [weak self, weak stacked] actionID in
			guard let stacked else { return }
			stacked.client?.send(["event": "action", "id": stacked.item.id, "action": actionID])
			self?.remove(stacked, notifyReason: nil)
		}
		card.onClose = { [weak self, weak stacked] in
			guard let stacked else { return }
			self?.remove(stacked, notifyReason: "user")
		}
		return card
	}

	private func remove(_ stacked: StackedItem, notifyReason: String?) {
		guard !stacked.isLeaving else { return }
		stacked.phase = .leaving(0)
		if let reason = notifyReason {
			stacked.client?.send(["event": "dismissed", "id": stacked.item.id, "reason": reason])
		}
		retarget()
	}

	/// Display order: permissions pin above idle cards; insertion order within
	/// each kind. An incoming idle card can never push a pending permission off
	/// screen.
	private func displayOrder() -> [StackedItem] {
		items.filter { !$0.isLeaving }.sorted {
			if $0.item.isPermission != $1.item.isPermission { return $0.item.isPermission }
			return $0.seq < $1.seq
		}
	}

	/// Recompute all spring targets from the current stack. Called on any
	/// membership change; the driver interpolates from wherever geometry
	/// currently is, so retargeting mid-flight is the normal case.
	private func retarget() {
		guard island != nil else { return }
		let visible = displayOrder()
		let opening = height.value < 1 && !visible.isEmpty

		if visible.isEmpty {
			// Closing springs are critically damped: bouncing on the way out just
			// looks indecisive.
			width.retarget(Double(startWidth), response: 0.34, damping: 1)
			height.retarget(0, response: 0.34, damping: 1)
		} else {
			let newStackWidth = visible.map(\.card.naturalWidth).max() ?? 340
			if newStackWidth != stackWidth {
				stackWidth = newStackWidth
				for stacked in items { stacked.card.layout(width: stackWidth) }
			} else {
				// A replaced card is created at natural width; re-flow it to match.
				for stacked in items where stacked.card.frame.width != stackWidth {
					stacked.card.layout(width: stackWidth)
				}
			}
			var offset: Double = 0
			for stacked in visible {
				if opening || height.value < 1 {
					stacked.offset.snap(to: offset)
				} else {
					stacked.offset.retarget(offset, response: 0.42, damping: 0.82)
				}
				offset += Double(stacked.card.cardHeight) + Double(separatorHeight)
			}
			let total = offset - Double(separatorHeight)
			settledHeight = max(total, 1)
			let islandW = Double(IslandView.islandWidth(cardWidth: stackWidth, notched: hasNotch))
			if opening {
				// Opening springs are under-damped: the island stretches past its
				// size and snaps back, which is the whole character of the thing.
				width.value = Double(startWidth)
				width.velocity = 0
				height.value = 0
				height.velocity = 0
				width.retarget(islandW, response: 0.42, damping: hasNotch ? 0.74 : 0.9)
				height.retarget(total, response: 0.42, damping: hasNotch ? 0.74 : 0.9)
			} else {
				width.retarget(islandW, response: 0.42, damping: 0.82)
				height.retarget(total, response: 0.42, damping: 0.82)
			}
		}
		startDriver()
	}

	private func startDriver() {
		guard let island else { return }
		if driver == nil {
			driver = FrameDriver { [weak self] dt in self?.tick(dt) ?? false }
		}
		driver?.start(in: island)
	}

	/// One animation frame: advance springs and per-card phases, lay everything
	/// out, and report whether anything is still moving.
	private func tick(_ dt: Double) -> Bool {
		guard let island else { return false }
		var moving = width.step(dt)
		moving = height.step(dt) || moving

		var finished: [StackedItem] = []
		for stacked in items {
			moving = stacked.offset.step(dt) || moving
			switch stacked.phase {
			case .entering(let t):
				let next = t + dt
				stacked.phase = next >= 0.4 ? .shown : .entering(next)
				if next < 0.4 { moving = true }
			case .leaving(let t):
				let next = t + dt
				if next >= 0.16 {
					finished.append(stacked)
				} else {
					stacked.phase = .leaving(next)
					moving = true
				}
			case .shown:
				break
			}
		}
		for stacked in finished {
			stacked.card.removeFromSuperview()
			stacked.separator.removeFromSuperlayer()
			items.removeAll { $0 === stacked }
		}

		layout(in: island)

		if items.isEmpty, height.settled, height.value == 0 {
			window?.orderOut(nil)
			stopHeartbeat()
			onEmptyRetracted?()
			return false
		}
		return moving
	}

	/// Position the silhouette, every card, and the hairline separators for the
	/// current animated values. All per-frame, all inside CATransaction-disabled
	/// actions via `render`.
	private func layout(in island: IslandView) {
		let h = height.value
		let progress = clamp01(h / min(settledHeight, 92))
		// Without a notch the island fades in as it blooms out of the menu bar;
		// under the housing it is always opaque (the collapsed sliver hides
		// behind the hardware anyway).
		let fade = hasNotch ? 1 : clamp01(h / 46)
		island.render(
			width: CGFloat(width.value), height: CGFloat(h), progress: progress, fade: fade)

		let topY = island.bounds.maxY
		let midX = island.bounds.midX
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let ordered = items.sorted { $0.offset.value < $1.offset.value }
		for stacked in items {
			let card = stacked.card
			let cardH = card.cardHeight
			let y = topY - CGFloat(stacked.offset.value) - cardH
			card.setFrameOrigin(NSPoint(x: midX - stackWidth / 2, y: y))

			var content: Double
			var alpha: Double = 1
			switch stacked.phase {
			case .entering(let t):
				// The content slides up out of its own top edge as it fades in, so
				// it looks poured into the island rather than revealed behind it.
				content = easeOut((t - 0.06) / 0.30)
			case .shown:
				content = 1
			case .leaving(let t):
				content = 1
				alpha = 1 - easeOut(t / 0.15)
			}
			let scaleY = 0.72 + 0.28 * CGFloat(content)
			let scaleX = 0.94 + 0.06 * CGFloat(content)
			var transform = CATransform3DMakeTranslation(0, cardH / 2 * (1 - scaleY), 0)
			transform = CATransform3DScale(transform, scaleX, scaleY, 1)
			card.layer?.transform = transform
			card.layer?.opacity = Float(clamp01(min(content * 1.4, alpha)))
		}
		// Hairline separators sit in the 1pt gaps between settled neighbors;
		// hidden for the top card and anything mid-flight.
		var previousBottom: CGFloat? = nil
		let visibleOrdered = ordered.filter { !$0.isLeaving }
		for stacked in items { stacked.separator.isHidden = true }
		for stacked in visibleOrdered {
			let top = topY - CGFloat(stacked.offset.value)
			if let prev = previousBottom {
				stacked.separator.isHidden = false
				stacked.separator.frame = CGRect(
					x: midX - stackWidth / 2 + 16, y: (top + prev) / 2 - separatorHeight / 2,
					width: stackWidth - 32, height: separatorHeight)
			}
			previousBottom = top - stacked.card.cardHeight
		}
		CATransaction.commit()
	}

	// MARK: Window and screen

	private func presentWindowIfNeeded() {
		if window == nil { buildWindow() }
		guard let window else { return }
		if !window.isVisible {
			width.snap(to: Double(startWidth))
			height.snap(to: 0)
			island.map { layout(in: $0) }
			window.orderFrontRegardless()
			// Insurance: if the system activated us anyway, hand focus straight back.
			if NSApp.isActive { NSApp.deactivate() }
		}
		startHeartbeat()
	}

	private func buildWindow() {
		guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
		let metrics = Self.metrics(for: screen)
		hasNotch = metrics.hasNotch
		startWidth = metrics.startWidth

		let islandView = IslandView(
			frame: NSRect(origin: .zero, size: metrics.windowRect.size), notched: hasNotch)
		let panel = NonActivatingPanel(
			contentRect: metrics.windowRect, styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered, defer: false)
		panel.hidesOnDeactivate = false
		panel.isFloatingPanel = true
		panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
		// Inert until the pointer poll finds the cursor over the silhouette, so
		// clicks anywhere in the (tall, mostly empty) band pass straight through
		// to whatever app is underneath.
		panel.ignoresMouseEvents = true
		panel.contentView = islandView
		window = panel
		island = islandView
	}

	/// A resident helper lives through dock/undock and resolution changes, so
	/// screen geometry is recomputed whenever the system says it moved — and the
	/// notched/notchless flip changes the silhouette style, not just position.
	private func screenChanged() {
		guard let window, let island else { return }
		guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
		let metrics = Self.metrics(for: screen)
		hasNotch = metrics.hasNotch
		startWidth = metrics.startWidth
		island.notched = metrics.hasNotch
		window.setFrame(metrics.windowRect, display: true)
		retarget()
		layout(in: island)
	}

	private struct ScreenMetrics {
		let hasNotch: Bool
		let startWidth: CGFloat
		let windowRect: NSRect
	}

	private static func metrics(for screen: NSScreen) -> ScreenMetrics {
		// Top anchor. The camera housing is a physical cutout with no pixels
		// behind it, so on notched Macs the island starts below it —
		// safeAreaInsets.top is the notch height. Notchless displays (external
		// monitors, docked mode) have no cutout to clear: the island anchors
		// flush to the screen's top edge and blooms over the empty center of
		// the menu bar, a virtual notch rather than a card hanging below it.
		let hasNotch = screen.safeAreaInsets.top > 0
		let topInset = hasNotch ? screen.safeAreaInsets.top : 0

		// The width the island grows out of and collapses back into. The areas
		// flanking the notch give its exact width; without a notch, pick a
		// pill-sized sliver so cards still bloom from the menu bar.
		let notchWidth: CGFloat = {
			guard hasNotch,
				let left = screen.auxiliaryTopLeftArea,
				let right = screen.auxiliaryTopRightArea
			else { return hasNotch ? 190 : 200 }
			return screen.frame.width - left.width - right.width
		}()

		// How far the island's top edge crosses the safe-area boundary. Under a
		// notch it tucks 2pt behind the housing's bottom edge so no hairline seam
		// separates the two black shapes; without a notch it sits exactly on the
		// screen's top edge.
		let overlap: CGFloat = hasNotch ? 2 : 0

		// The window is a fixed tall band sized for the largest possible stack:
		// it never moves or resizes while animating, which keeps the whole morph
		// on the render server. Only the island inside it grows and shrinks, and
		// the window is click-through except while the pointer sits on the
		// silhouette itself.
		let slack = IslandView.slack
		let maxIslandWidth = IslandView.islandWidth(cardWidth: 560, notched: true)
		let bandWidth = maxIslandWidth + slack * 2
		let bandHeight = min(screen.visibleFrame.height, 640) + slack
		let top = screen.frame.maxY - topInset + overlap
		let rect = NSRect(
			x: screen.frame.midX - bandWidth / 2, y: top - bandHeight,
			width: bandWidth, height: bandHeight)
		let startWidth = min(notchWidth, maxIslandWidth)
		return ScreenMetrics(
			hasNotch: hasNotch, startWidth: startWidth, windowRect: rect)
	}

	// MARK: Heartbeat: pointer poll + dwell/timeout clock

	/// A 10 Hz heartbeat while the island is visible. Polling NSEvent's global
	/// mouse location instead of tracking areas sidesteps both open questions of
	/// a never-active accessory app — whether enter/exit fire reliably, and how
	/// to click *through* the empty parts of the band: the window is
	/// `ignoresMouseEvents` except while the pointer is over the silhouette.
	private func startHeartbeat() {
		guard heartbeat == nil else { return }
		lastHeartbeat = CACurrentMediaTime()
		let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pulse() }
		timer.tolerance = 0.02
		RunLoop.main.add(timer, forMode: .common)
		heartbeat = timer
	}

	private func stopHeartbeat() {
		heartbeat?.invalidate()
		heartbeat = nil
	}

	private func pulse() {
		let now = CACurrentMediaTime()
		let dt = now - lastHeartbeat
		lastHeartbeat = now
		guard let window, let island, window.isVisible else { return }

		// Pointer over the silhouette?
		let mouse = NSEvent.mouseLocation
		let local = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
		let inside = island.contains(local)
		if inside != hovered {
			hovered = inside
			window.ignoresMouseEvents = !inside
			for stacked in items where !stacked.isLeaving { stacked.card.setHovered(inside) }
			if !inside {
				// Resume with a short grace rather than the residual remainder, so
				// a card does not vanish the instant the pointer leaves it.
				for stacked in items where stacked.dwellRemaining >= 0 {
					stacked.dwellRemaining = max(stacked.dwellRemaining, hoverGrace)
				}
			}
		}

		// Dwell counts down only while unhovered; the hard timeout always does.
		for stacked in items where !stacked.isLeaving {
			if let deadline = stacked.timeoutAt, now >= deadline {
				remove(stacked, notifyReason: "timeout")
				continue
			}
			if stacked.dwellRemaining >= 0, !hovered {
				stacked.dwellRemaining -= dt
				if stacked.dwellRemaining <= 0 {
					remove(stacked, notifyReason: "timeout")
				}
			}
		}
	}
}

// MARK: - Servers

/// Shared command dispatch for both serve transports.
func handleLine(_ line: String, client: ClientRef, controller: NotchController) {
	guard let data = line.data(using: .utf8),
		let command = try? JSONDecoder().decode(WireCommand.self, from: data)
	else {
		logError("notch: ignoring undecodable line")
		return
	}
	switch command.cmd {
	case "show":
		guard command.id?.isEmpty == false else { return }
		controller.show(NotchItem(command: command), client: client)
	case "update":
		// Like show, but only if the card is still on screen: late-arriving
		// enrichment (git stats land after the dwell expired) must not resurrect
		// a dismissed card.
		guard command.id?.isEmpty == false else { return }
		controller.show(NotchItem(command: command), client: client, updateOnly: true)
	case "dismiss":
		guard let id = command.id else { return }
		controller.dismiss(id: id, client: client)
	case "clear":
		controller.clear(client: client)
	default:
		break // unknown commands are ignored, not fatal
	}
}

func helperVersion() -> String {
	(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}

/// `--serve`: NDJSON on stdio. Lifetime is the parent's — EOF retracts
/// everything and exits.
final class StdioServer {
	private let controller: NotchController
	private var reader: LineReader?
	private let client: ClientRef

	init(controller: NotchController) {
		self.controller = controller
		client = ClientRef(id: 0, writer: FDWriter(fd: 1))
	}

	func start() {
		client.send(["event": "ready", "version": helperVersion()])
		reader = LineReader(
			fd: 0,
			onLine: { [controller, client] line in
				handleLine(line, client: client, controller: controller)
			},
			onEOF: { [controller] in
				controller.clear(client: nil)
				controller.onEmptyRetracted = { NSApp.terminate(nil) }
				if controller.isEmpty { NSApp.terminate(nil) }
				// If the retract wedges, don't linger as an orphan.
				DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
			})
	}
}

/// Path for async-signal-safe cleanup: SIGTERM may only unlink and _exit.
private var socketCleanupPath: UnsafeMutablePointer<CChar>?

/// `--serve --socket PATH`: a daemon shared by every OpenCode instance, so
/// cards from all of them stack in one island. What stdio gave for free is
/// built explicitly here, each piece deliberately boring:
/// - No version negotiation — the plugin embeds its version in the path, so
///   mismatched versions simply run separate daemons.
/// - The launch race is arbitrated by bind(2): the loser exits silently.
/// - Lifetime: exits ~10s after the last client disconnects (or if nobody
///   connects at all), unlinking the socket on the way out.
final class SocketServer {
	private let path: String
	private let controller: NotchController
	private var listenFD: Int32 = -1
	private var acceptSource: DispatchSourceRead?
	private var clients: [Int: (fd: Int32, client: ClientRef, reader: LineReader)] = [:]
	private var nextClientID = 1
	private var lingerTimer: Timer?
	private let linger: TimeInterval = 10

	init(path: String, controller: NotchController) {
		self.path = path
		self.controller = controller
	}

	private static func makeAddr(_ path: String) -> sockaddr_un? {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8)
		let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
		guard bytes.count <= capacity else { return nil }
		withUnsafeMutableBytes(of: &addr.sun_path) { dst in
			for (i, b) in bytes.enumerated() { dst[i] = b }
		}
		return addr
	}

	private static func withSockaddr<T>(
		_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
	) -> T {
		withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
	}

	/// True if a live daemon already answers on the path.
	private static func probe(_ path: String) -> Bool {
		guard var addr = makeAddr(path) else { return false }
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return false }
		defer { close(fd) }
		return withSockaddr(&addr) { sa, len in connect(fd, sa, len) == 0 }
	}

	/// Returns false when another daemon owns the path (probe answered, or we
	/// lost the bind race) — the caller should exit quietly.
	func start() -> Bool {
		guard var addr = Self.makeAddr(path) else {
			logError("notch: socket path too long: \(path)")
			return false
		}
		if Self.probe(path) { return false }
		// The probe failed, so anything at the path is a stale corpse from a
		// crashed daemon.
		unlink(path)
		listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
		guard listenFD >= 0 else { return false }
		let bound = Self.withSockaddr(&addr) { sa, len in bind(listenFD, sa, len) == 0 }
		guard bound, listen(listenFD, 16) == 0 else {
			close(listenFD)
			return false
		}

		socketCleanupPath = strdup(path)
		signal(SIGTERM) { _ in
			if let p = socketCleanupPath { unlink(p) }
			_exit(0)
		}

		let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
		source.setEventHandler { [weak self] in self?.acceptClient() }
		source.resume()
		acceptSource = source
		scheduleLinger()
		return true
	}

	private func acceptClient() {
		let fd = accept(listenFD, nil, nil)
		guard fd >= 0 else { return }
		let id = nextClientID
		nextClientID += 1
		let client = ClientRef(id: id, writer: FDWriter(fd: fd))
		let reader = LineReader(
			fd: fd,
			onLine: { [weak self] line in
				guard let self else { return }
				handleLine(line, client: client, controller: self.controller)
			},
			onEOF: { [weak self] in self?.dropClient(id) })
		clients[id] = (fd, client, reader)
		client.send(["event": "ready", "version": helperVersion()])
		lingerTimer?.invalidate()
		lingerTimer = nil
	}

	private func dropClient(_ id: Int) {
		guard let entry = clients.removeValue(forKey: id) else { return }
		entry.reader.cancel()
		close(entry.fd)
		// That client's OpenCode exited or crashed; its cards go with it.
		controller.dropClient(id)
		if clients.isEmpty { scheduleLinger() }
	}

	private func scheduleLinger() {
		lingerTimer?.invalidate()
		let timer = Timer(timeInterval: linger, repeats: false) { [weak self] _ in
			guard let self, self.clients.isEmpty else { return }
			self.shutdown()
		}
		RunLoop.main.add(timer, forMode: .common)
		lingerTimer = timer
	}

	private func shutdown() {
		controller.clear(client: nil)
		let path = self.path
		let finish = {
			unlink(path)
			exit(0)
		}
		if controller.isEmpty {
			finish()
		} else {
			controller.onEmptyRetracted = { finish() }
			DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
		}
	}
}

// MARK: - Main

@main
@MainActor
enum NotchApp {
	// Servers live for the process; kept here so ARC doesn't collect them.
	private static var stdioServer: StdioServer?
	private static var socketServer: SocketServer?
	private static let controller = NotchController()

	static func main() {
		signal(SIGPIPE, SIG_IGN)
		let args = CommandLine.arguments
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		if args.contains("--serve") {
			if let flag = args.firstIndex(of: "--socket"), flag + 1 < args.count {
				let server = SocketServer(path: args[flag + 1], controller: controller)
				guard server.start() else { exit(0) } // another daemon owns the path
				socketServer = server
			} else {
				let server = StdioServer(controller: controller)
				server.start()
				stdioServer = server
			}
		} else {
			// Legacy one-shot: positional argv, one card, exit after it retracts.
			controller.onEmptyRetracted = { app.terminate(nil) }
			controller.show(NotchItem(argv: args), client: nil)
		}

		app.run()
	}
}
