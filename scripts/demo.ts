// Scripted showcase of every card the notch helper can draw, for development
// and for anyone evaluating the plugin without wiring it into OpenCode first.
// Run: bun run demo (after `bun run build:swift`).
//
// The helper runs in stdio mode rather than as the shared socket daemon, so
// the demo owns it outright: EOF on stdin retracts every card and exits the
// helper, which means no island can outlive this script.

import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const bin = join(root, "swift", "notch.app", "Contents", "MacOS", "notch")

if (!existsSync(bin)) {
	console.error("Helper binary missing — run `bun run build:swift` first.")
	process.exit(1)
}

const proc = Bun.spawn([bin, "--serve"], { stdin: "pipe", stdout: "pipe", stderr: "inherit" })

type HelperEvent = {
	event?: string
	id?: string
	action?: string
	reason?: string
	version?: string
}

/** Pretty-print helper events as they arrive; settles when stdout closes. */
const reading = (async () => {
	const decoder = new TextDecoder()
	let buffer = ""
	for await (const chunk of proc.stdout) {
		buffer += decoder.decode(chunk, { stream: true })
		let newline: number
		while ((newline = buffer.indexOf("\n")) >= 0) {
			const line = buffer.slice(0, newline)
			buffer = buffer.slice(newline + 1)
			if (!line) continue
			let event: HelperEvent
			try {
				event = JSON.parse(line) as HelperEvent
			} catch {
				// Unknown output is still worth seeing while poking at the protocol.
				console.log(`<- ${line}`)
				continue
			}
			const detail = [event.id, event.action, event.reason, event.version && `v${event.version}`]
			console.log(`<- ${[event.event ?? "?", ...detail.filter(Boolean)].join(" ")}`)
		}
	}
})()

function send(command: Record<string, unknown> & { cmd: string; id?: string }) {
	console.log(`-> ${[command.cmd, command.id].filter(Boolean).join(" ")}`)
	proc.stdin.write(JSON.stringify(command) + "\n")
	proc.stdin.flush()
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// Ctrl-C: EOF is the helper's retract-and-exit signal, so close stdin and let
// the island pull itself back in instead of leaving it stranded on screen.
process.on("SIGINT", () => {
	proc.stdin.end()
	void proc.exited.then(() => process.exit(130))
})

// Sticky (`dwell: 0`) throughout: the script paces the showcase, not the dwell
// timer, so every card stays up long enough to look at.
const idle = {
	cmd: "show",
	id: "idle:demo",
	kind: "idle",
	dwell: 0,
	timeout: 60,
	title: "opencode-notch",
	subtitle: "Demo: response ready",
}

send(idle)
await sleep(1500)

// Same id, `update`: the path the plugin takes when `git diff` and `gh pr view`
// come back after the card is already up. It fills in place, without replaying
// the drop animation.
send({ ...idle, cmd: "update", branch: "main", pr: "42", files: 3, additions: 42, deletions: 10 })
await sleep(2000)

// A different id stacks inside the same island instead of replacing the first.
send({ ...idle, id: "idle:demo-2", subtitle: "Demo: a second session finished" })
await sleep(2000)

// Permission cards pin above idle ones and carry buttons; clicking one retracts
// the card and emits an `action` event, printed by the reader above.
send({
	cmd: "show",
	id: "perm:demo",
	kind: "permission",
	dwell: 0,
	timeout: 30,
	title: "bash",
	subtitle: "rm -rf build",
	mono: true,
	meta: "Demo session",
	actions: [
		{ id: "once", label: "Allow", style: "primary" },
		{ id: "always", label: "Always", style: "default" },
		{ id: "reject", label: "Deny", style: "danger" },
	],
})

console.log("Hover the island to hold it open, or click a permission button.")
await sleep(6000)

for (const id of ["idle:demo", "idle:demo-2", "perm:demo"]) send({ cmd: "dismiss", id })
send({ cmd: "clear" })
proc.stdin.end()
await proc.exited
await reading
