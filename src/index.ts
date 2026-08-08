import { existsSync, readFileSync, statSync, unlinkSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { type Plugin } from "@opencode-ai/plugin"

// Escape a string for use inside an AppleScript double-quoted literal.
const esc = (s: string) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const notch = join(root, "swift", "notch.app")
const notchBin = join(notch, "Contents", "MacOS", "notch")

// The plugin version is baked into the socket path instead of negotiated over
// it: two plugin versions simply run two daemons, which self-heals as
// instances restart. $TMPDIR is per-user on macOS, so the path is private and
// short enough for sun_path's 104-byte limit.
const version = (() => {
	try {
		return JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version ?? "dev"
	} catch {
		return "dev"
	}
})()
const socketPath = join(tmpdir(), `opencode-notch-${version}.sock`)

type ShowPayload = Record<string, unknown> & { cmd: "show"; id: string }
type HelperEvent = {
	event?: string
	id?: string
	action?: string
	reason?: string
	version?: string
}

type Shell = Awaited<Parameters<Plugin>[0]>["$"]

/**
 * Supervises the connection to the shared notch daemon: dials the socket,
 * spawns the daemon via `open -g -n` when nobody answers (LaunchServices
 * detaches it and honors LSUIElement, so it never steals focus), clears
 * stale socket corpses, and backs off after repeated failures instead of
 * hammering a broken helper on every event.
 */
class Helper {
	private socket: Bun.Socket | null = null
	private dialing: Promise<Bun.Socket | null> | null = null
	private failures = 0
	private disabledUntil = 0
	private buffer = ""

	constructor(
		private $: Shell,
		private onEvent: (event: HelperEvent) => void,
		private onConnected: () => void,
	) {}

	/** Send one protocol line; false means the helper is unavailable. */
	async send(message: Record<string, unknown>): Promise<boolean> {
		const socket = this.socket ?? (await this.connect())
		if (!socket) return false
		try {
			socket.write(JSON.stringify(message) + "\n")
			return true
		} catch {
			this.socket = null
			return false
		}
	}

	private async connect(): Promise<Bun.Socket | null> {
		if (this.socket) return this.socket
		if (Date.now() < this.disabledUntil) return null
		// Single-flight: a burst of events must not spawn a herd of daemons.
		this.dialing ??= this.establish().finally(() => {
			this.dialing = null
		})
		return this.dialing
	}

	private async establish(): Promise<Bun.Socket | null> {
		try {
			return this.adopt(await this.dial())
		} catch {}
		if (!existsSync(notchBin)) {
			this.markFailure()
			return null
		}
		// Nobody answered: anything at the path is a stale corpse from a crashed
		// daemon. Remove it so the fresh daemon can bind.
		try {
			unlinkSync(socketPath)
		} catch {}
		try {
			await this.$`open -g -n ${notch} --args --serve --socket ${socketPath}`.quiet().nothrow()
		} catch {}
		// If several OpenCode instances spawn at once, bind(2) arbitrates on the
		// daemon side: losers exit and these retries land on the winner.
		for (const delay of [150, 300, 600, 1200, 2400]) {
			await new Promise((resolve) => setTimeout(resolve, delay))
			try {
				return this.adopt(await this.dial())
			} catch {}
		}
		this.markFailure()
		return null
	}

	private adopt(socket: Bun.Socket): Bun.Socket {
		this.socket = socket
		this.failures = 0
		this.disabledUntil = 0
		this.buffer = ""
		this.onConnected()
		return socket
	}

	private markFailure() {
		this.failures += 1
		// 1s, 4s, 16s, then a minute between attempts — a broken helper must not
		// cost four subprocess spawns per session event forever.
		const backoff = [1_000, 4_000, 16_000][this.failures - 1] ?? 60_000
		this.disabledUntil = Date.now() + backoff
	}

	private dial(): Promise<Bun.Socket> {
		return Bun.connect({
			unix: socketPath,
			socket: {
				data: (_socket, chunk) => {
					this.buffer += chunk.toString()
					let newline: number
					while ((newline = this.buffer.indexOf("\n")) >= 0) {
						const line = this.buffer.slice(0, newline)
						this.buffer = this.buffer.slice(newline + 1)
						if (!line) continue
						try {
							this.onEvent(JSON.parse(line) as HelperEvent)
						} catch {}
					}
				},
				close: (socket) => {
					// The daemon died or dropped us; it also dropped our cards. The
					// next send reconnects (and possibly respawns) lazily.
					if (this.socket === socket) this.socket = null
				},
				error: () => {},
			},
		})
	}
}

/**
 * Locate the repository's git directory by walking up from `start`, the way
 * git itself does. `.git` is a directory in a normal clone and a file holding
 * `gitdir: <path>` in a linked work tree or submodule. Returns null outside a
 * work tree (or when a `GIT_DIR`-style setup hides it), which is the signal to
 * fall back to asking git in a subprocess.
 */
function findGitDir(start: string): string | null {
	let dir = start
	for (;;) {
		const dot = join(dir, ".git")
		try {
			const stat = statSync(dot)
			if (stat.isDirectory()) return dot
			if (stat.isFile()) {
				const pointer = readFileSync(dot, "utf8").trim()
				if (pointer.startsWith("gitdir:")) {
					const target = pointer.slice(7).trim()
					return target.startsWith("/") ? target : join(dir, target)
				}
			}
		} catch {}
		const parent = dirname(dir)
		if (parent === dir) return null
		dir = parent
	}
}

/**
 * The current branch, read straight out of `HEAD`. `git branch --show-current`
 * is a subprocess spawn plus a repository discovery walk; this is a single
 * ~40-byte read, so the branch can ride along on the very first frame of the
 * card instead of arriving as a late update. Detached HEAD yields the short
 * hash, matching `git rev-parse --short HEAD`.
 */
function readBranch(gitDir: string): string {
	let head: string
	try {
		head = readFileSync(join(gitDir, "HEAD"), "utf8").trim()
	} catch {
		return ""
	}
	if (head.startsWith("ref:")) {
		const ref = head.slice(4).trim()
		return ref.startsWith("refs/heads/") ? ref.slice(11) : (ref.split("/").pop() ?? "")
	}
	return /^[0-9a-f]{40,}$/.test(head) ? head.slice(0, 7) : ""
}

export const NotchPlugin: Plugin = async ({ client, $, directory }) => {
	const project = basename(directory) || "opencode"

	// Pending permission cards by permission id. Used to route button presses
	// back to the reply endpoint, and to re-show cards after a daemon restart
	// (a fresh daemon starts with an empty island).
	const pending = new Map<string, { sessionID: string; show: ShowPayload }>()

	const helper = new Helper(
		$,
		(event) => {
			void handleHelperEvent(event)
		},
		() => {
			for (const entry of pending.values()) void helper.send(entry.show)
		},
	)

	async function handleHelperEvent(event: HelperEvent) {
		if (!event.id?.startsWith("perm:")) return
		const permissionID = event.id.slice(5)
		if (event.event === "action") {
			const entry = pending.get(permissionID)
			if (!entry) return
			pending.delete(permissionID)
			const response = event.action
			if (response !== "once" && response !== "always" && response !== "reject") return
			try {
				// The same endpoint the TUI's own Allow-once/Always/Deny hits. A 400
				// or 404 just means the permission was answered elsewhere first —
				// the outcome is already correct.
				await client.postSessionIdPermissionsPermissionId({
					path: { id: entry.sessionID, permissionID },
					body: { response },
				})
			} catch {}
		} else if (event.event === "dismissed") {
			// The card timed out unanswered. The permission stays pending in the
			// TUI — deliberately no invented answer — but stop re-showing it.
			pending.delete(permissionID)
		}
	}

	// The git directory is resolved once per project. Only a hit is cached: a
	// miss re-walks on the next event, so `git init` mid-session heals itself.
	let cachedGitDir: string | null = null
	function gitDir(): string | null {
		cachedGitDir ??= findGitDir(directory)
		return cachedGitDir
	}

	/** Branch without a subprocess, so it can ship with the first frame. */
	function fastBranch(): string {
		const dir = gitDir()
		return dir ? readBranch(dir) : ""
	}

	/** Branch the slow way, for repos whose layout the file read cannot see. */
	async function slowBranch(): Promise<string> {
		const [rawBranch, shortHead] = await Promise.all([
			$`git branch --show-current`.cwd(directory).quiet().nothrow().text(),
			// Detached HEAD: fall back to the short commit hash.
			$`git rev-parse --short HEAD`.cwd(directory).quiet().nothrow().text(),
		])
		return rawBranch.trim() || shortHead.trim()
	}

	// The session summary is reset to zeros and computed asynchronously after
	// idle, so it is unreliable at notification time. Compute diff stats
	// directly from git instead.
	async function diffStats(): Promise<{ files: number; additions: number; deletions: number }> {
		const numstat = await $`git diff --numstat HEAD`.cwd(directory).quiet().nothrow().text()
		let files = 0
		let additions = 0
		let deletions = 0
		for (const line of numstat.trim().split("\n")) {
			if (!line) continue
			const cols = line.split("\t")
			if (cols.length < 3) continue
			const a = cols[0] === "-" ? 0 : parseInt(cols[0], 10)
			const d = cols[1] === "-" ? 0 : parseInt(cols[1], 10)
			if (!isNaN(a)) additions += a
			if (!isNaN(d)) deletions += d
			files++
		}
		return { files, additions, deletions }
	}

	// gh exits non-zero when there is no PR, gh is missing, or the repo has no
	// GitHub remote; any of those just hides the PR.
	async function prNumber(): Promise<string> {
		const out = await $`gh pr view --json number --jq .number`.cwd(directory).quiet().nothrow().text()
		return out.trim()
	}

	async function isWorkTree(): Promise<boolean> {
		return (
			(await $`git rev-parse --is-inside-work-tree`.cwd(directory).quiet().nothrow().text()).trim() ===
			"true"
		)
	}

	/** Everything at once — only the one-shot fallback, which cannot update. */
	async function gatherGit() {
		if (!gitDir() && !(await isWorkTree())) return null
		const [branch, stats, pr] = await Promise.all([
			fastBranch() || slowBranch(),
			diffStats(),
			prNumber(),
		])
		return { ...stats, branch, pr }
	}

	/**
	 * Fill in what the first frame could not carry, each piece landing as soon
	 * as it is known instead of at the pace of the slowest one — `gh pr view`
	 * is a network round trip and must not hold up local diff stats.
	 */
	async function enrich(show: ShowPayload, branch: string) {
		if (!gitDir() && !(await isWorkTree())) return
		// Every update rebuilds the card from the payload, so accumulate rather
		// than sending each piece on its own.
		const known: Record<string, unknown> = branch ? { branch } : {}
		const merge = async (patch: Record<string, unknown>) => {
			Object.assign(known, patch)
			await helper.send({ ...show, ...known, cmd: "update" })
		}
		// Nothing to say is not worth a frame: an empty diff or a branch with no
		// PR leaves the card exactly as it was shown.
		await Promise.all([
			branch ? undefined : slowBranch().then((b) => (b ? merge({ branch: b }) : undefined)),
			diffStats().then((stats) => (stats.files > 0 ? merge(stats) : undefined)),
			prNumber().then((pr) => (pr ? merge({ pr }) : undefined)),
		])
	}

	async function fallbackNotify(title: string, body: string) {
		if (existsSync(notch)) {
			// One-shot legacy path: LaunchServices honors LSUIElement; -g prevents
			// foreground activation.
			const git = (await gatherGit()) ?? { files: 0, additions: 0, deletions: 0, branch: "", pr: "" }
			$`open -g -n ${notch} --args ${title} ${body} ${git.files} ${git.additions} ${git.deletions} ${git.branch} ${git.pr}`
				.quiet()
				.nothrow()
				.catch(() => {})
		} else {
			// Binary not built; fall back to a standard notification.
			const script = `display notification "${esc(body)}" with title "${esc(title)}"`
			await $`osascript -e ${script}`
		}
	}

	async function onSessionIdle(sessionID: string) {
		const session = await client.session.get({ path: { id: sessionID } })
		// Skip subagent (child) sessions; only notify when the main session finishes.
		if (!session.data || session.data.parentID) return
		const body = session.data.title || "Response ready"
		// Per-session id: a second idle for the same session replaces its card in
		// place instead of stacking a duplicate — this is what replaced the old
		// global debounce.
		// Read off HEAD, not out of a subprocess, so the meta line is populated on
		// the card's very first frame instead of appearing a beat later.
		const branch = fastBranch()
		const show: ShowPayload = {
			cmd: "show",
			id: `idle:${sessionID}`,
			kind: "idle",
			dwell: 2.8,
			timeout: 60,
			title: project,
			subtitle: body,
			...(branch ? { branch } : {}),
		}
		// Show immediately from session data plus the branch; diff stats and the
		// PR lookup stay off the critical path and arrive as same-id in-place
		// updates.
		if (!(await helper.send(show))) {
			await fallbackNotify(project, body)
			return
		}
		try {
			await enrich(show, branch)
		} catch {}
	}

	async function onPermissionUpdated(permission: {
		id: string
		type: string
		pattern?: string | Array<string>
		sessionID: string
		title: string
		metadata: { [key: string]: unknown }
	}) {
		// Unlike session.idle, child sessions are NOT skipped: a subagent's
		// permission still needs answering. The session title on the meta line
		// says which task is asking.
		let meta = ""
		try {
			const session = await client.session.get({ path: { id: permission.sessionID } })
			meta = session.data?.title ?? ""
		} catch {}
		const command =
			typeof permission.metadata?.command === "string" ? permission.metadata.command : ""
		const pattern = Array.isArray(permission.pattern)
			? permission.pattern.join("  ")
			: (permission.pattern ?? "")
		const show: ShowPayload = {
			cmd: "show",
			id: `perm:${permission.id}`,
			kind: "permission",
			// Sticky (the buttons are the dismissal), but hard-capped: after the
			// timeout the card retracts without inventing an answer — the
			// permission stays pending in the TUI, which is the correct fallback.
			dwell: 0,
			timeout: 120,
			title: permission.title || permission.type,
			subtitle: command || pattern,
			mono: Boolean(command || pattern),
			meta,
			actions: [
				{ id: "once", label: "Allow", style: "primary" },
				{ id: "always", label: "Always", style: "default" },
				{ id: "reject", label: "Deny", style: "danger" },
			],
		}
		pending.set(permission.id, { sessionID: permission.sessionID, show })
		// No one-shot fallback for permission cards: a card without working
		// buttons would just be a lie about being answerable.
		if (!(await helper.send(show))) pending.delete(permission.id)
	}

	return {
		event: async ({ event }) => {
			try {
				switch (event.type) {
					case "session.idle":
						await onSessionIdle(event.properties.sessionID)
						break
					case "permission.updated":
						await onPermissionUpdated(event.properties)
						break
					case "permission.replied": {
						// Answered (in the TUI, or via our own button press): the card is
						// stale either way.
						const { permissionID } = event.properties
						pending.delete(permissionID)
						void helper.send({ cmd: "dismiss", id: `perm:${permissionID}` })
						break
					}
					case "session.deleted": {
						const sessionID = event.properties.info.id
						void helper.send({ cmd: "dismiss", id: `idle:${sessionID}` })
						for (const [permissionID, entry] of pending) {
							if (entry.sessionID !== sessionID) continue
							pending.delete(permissionID)
							void helper.send({ cmd: "dismiss", id: `perm:${permissionID}` })
						}
						break
					}
				}
			} catch {
				// A failed notification must never break the event bus.
			}
		},
	}
}

export default NotchPlugin
