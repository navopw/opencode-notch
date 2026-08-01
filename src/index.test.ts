import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

// The plugin resolves its socket path at import time, so the override must be
// in place before the module is loaded (dynamically, in beforeAll). A unique
// temp dir keeps parallel runs from colliding with each other or with a real
// daemon on the developer's machine.
const testDir = mkdtempSync(join(tmpdir(), "notch-test-"))
const socketPath = join(testDir, "d.sock")
process.env.OPENCODE_NOTCH_SOCKET = socketPath

type Line = Record<string, any>

/**
 * In-process stand-in for the Swift daemon: accepts connections on the test
 * socket, records every NDJSON line it receives, and can push protocol events
 * back to the client under test.
 */
function startFakeDaemon() {
	const lines: Line[] = []
	const clients: Bun.Socket<undefined>[] = []
	const buffers = new Map<Bun.Socket<undefined>, string>()
	const listener = Bun.listen<undefined>({
		unix: socketPath,
		socket: {
			open(socket) {
				clients.push(socket)
				buffers.set(socket, "")
			},
			data(socket, chunk) {
				let buffer = (buffers.get(socket) ?? "") + chunk.toString()
				let newline: number
				while ((newline = buffer.indexOf("\n")) >= 0) {
					const line = buffer.slice(0, newline)
					buffer = buffer.slice(newline + 1)
					if (line) lines.push(JSON.parse(line) as Line)
				}
				buffers.set(socket, buffer)
			},
			close(socket) {
				const index = clients.indexOf(socket)
				if (index >= 0) clients.splice(index, 1)
				buffers.delete(socket)
			},
			error() {},
		},
	})
	return {
		lines,
		// Each test creates its own plugin instance, so the most recent
		// connection is the one under test.
		send(event: Line) {
			clients[clients.length - 1]?.write(JSON.stringify(event) + "\n")
		},
		closeClients() {
			for (const client of [...clients]) client.end()
		},
		stop() {
			listener.stop(true)
		},
	}
}

type Chain = {
	cwd: () => Chain
	quiet: () => Chain
	nothrow: () => Chain
	catch: (onrejected: unknown) => Promise<void>
	text: () => Promise<string>
}

// Template-tag stand-in for Bun's $. `git rev-parse --is-inside-work-tree`
// answers "false" so gatherGit bails out and no real subprocess ever runs.
function makeShell() {
	return (strings: TemplateStringsArray, ...values: unknown[]) => {
		const command = strings.raw.reduce(
			(acc, part, i) => acc + part + (i < values.length ? String(values[i]) : ""),
			"",
		)
		const chain: Chain = {
			cwd: () => chain,
			quiet: () => chain,
			nothrow: () => chain,
			catch: () => Promise.resolve(),
			text: async () => (command.includes("--is-inside-work-tree") ? "false" : ""),
		}
		return chain
	}
}

const sessions: Record<string, { id: string; title: string; parentID?: string }> = {
	"s-main": { id: "s-main", title: "Ship the release" },
	"s-child": { id: "s-child", title: "Subtask", parentID: "s-main" },
}

function makeClient() {
	const permissionReplies: Array<{
		path: { id: string; permissionID: string }
		body: { response: string }
	}> = []
	const client = {
		session: {
			get: async ({ path }: { path: { id: string } }) => ({ data: sessions[path.id] ?? null }),
		},
		postSessionIdPermissionsPermissionId: async (args: {
			path: { id: string; permissionID: string }
			body: { response: string }
		}) => {
			permissionReplies.push(args)
			return {}
		},
	}
	return { client, permissionReplies }
}

let daemon: ReturnType<typeof startFakeDaemon>
let NotchPlugin: (typeof import("./index"))["NotchPlugin"]

beforeAll(async () => {
	// The daemon must be listening before the plugin's first send, so it never
	// falls into the spawn-a-real-daemon path.
	daemon = startFakeDaemon()
	;({ NotchPlugin } = await import("./index"))
})

afterAll(() => {
	daemon.stop()
	rmSync(testDir, { recursive: true, force: true })
})

beforeEach(() => {
	daemon.lines.length = 0
})

async function makePlugin() {
	const { client, permissionReplies } = makeClient()
	const hooks = await NotchPlugin({
		client,
		$: makeShell(),
		directory: "/tmp/fake-project",
	} as any)
	const emit = (event: Line) => hooks.event!({ event } as any)
	return { emit, permissionReplies }
}

async function waitFor<T>(probe: () => T, timeoutMs = 2000): Promise<NonNullable<T>> {
	const deadline = Date.now() + timeoutMs
	for (;;) {
		const value = probe()
		if (value) return value as NonNullable<T>
		if (Date.now() > deadline) throw new Error("timed out waiting for condition")
		await Bun.sleep(10)
	}
}

const idle = (sessionID: string) => ({ type: "session.idle", properties: { sessionID } })
const permission = (id: string, sessionID: string) => ({
	type: "permission.updated",
	properties: {
		id,
		type: "bash",
		sessionID,
		title: "Run command",
		metadata: { command: "git status" },
	},
})

test("session.idle on a main session shows an idle card", async () => {
	const { emit } = await makePlugin()
	await emit(idle("s-main"))
	const show = await waitFor(() => daemon.lines.find((l) => l.id === "idle:s-main"))
	expect(show.cmd).toBe("show")
	expect(show.kind).toBe("idle")
	expect(show.title).toBe("fake-project")
	expect(show.subtitle).toBe("Ship the release")
})

test("session.idle on a child session sends nothing", async () => {
	const { emit } = await makePlugin()
	await emit(idle("s-child"))
	// A follow-up main-session idle acts as the fence: once its card arrives,
	// anything the child idle would have sent must already be here.
	await emit(idle("s-main"))
	await waitFor(() => daemon.lines.find((l) => l.id === "idle:s-main"))
	expect(daemon.lines.filter((l) => l.id === "idle:s-child")).toEqual([])
})

test("a second idle for the same session reuses the card id", async () => {
	const { emit } = await makePlugin()
	await emit(idle("s-main"))
	await emit(idle("s-main"))
	const shows = await waitFor(() => {
		const found = daemon.lines.filter((l) => l.cmd === "show" && l.id === "idle:s-main")
		return found.length === 2 ? found : undefined
	})
	expect(shows[0].id).toBe(shows[1].id)
})

test("permission.updated shows an actionable permission card", async () => {
	const { emit } = await makePlugin()
	await emit(permission("p1", "s-main"))
	const show = await waitFor(() => daemon.lines.find((l) => l.id === "perm:p1"))
	expect(show.cmd).toBe("show")
	expect(show.kind).toBe("permission")
	expect(show.dwell).toBe(0)
	expect(show.subtitle).toBe("git status")
	expect(show.meta).toBe("Ship the release")
	expect(show.actions.map((action: Line) => action.id)).toEqual(["once", "always", "reject"])
})

test("a button press on the card replies to the permission endpoint", async () => {
	const { emit, permissionReplies } = await makePlugin()
	await emit(permission("p2", "s-main"))
	await waitFor(() => daemon.lines.find((l) => l.id === "perm:p2"))
	daemon.send({ event: "action", id: "perm:p2", action: "once" })
	const reply = await waitFor(() => permissionReplies[0])
	expect(reply.path).toEqual({ id: "s-main", permissionID: "p2" })
	expect(reply.body).toEqual({ response: "once" })
})

test("permission.replied dismisses the card", async () => {
	const { emit } = await makePlugin()
	await emit(permission("p3", "s-main"))
	await waitFor(() => daemon.lines.find((l) => l.id === "perm:p3"))
	await emit({ type: "permission.replied", properties: { sessionID: "s-main", permissionID: "p3" } })
	await waitFor(() => daemon.lines.find((l) => l.cmd === "dismiss" && l.id === "perm:p3"))
})

test("session.deleted dismisses the idle card and pending permissions", async () => {
	const { emit } = await makePlugin()
	await emit(idle("s-main"))
	await emit(permission("p4", "s-main"))
	await waitFor(() => daemon.lines.find((l) => l.id === "perm:p4"))
	await emit({ type: "session.deleted", properties: { info: { id: "s-main" } } })
	await waitFor(() => daemon.lines.find((l) => l.cmd === "dismiss" && l.id === "idle:s-main"))
	await waitFor(() => daemon.lines.find((l) => l.cmd === "dismiss" && l.id === "perm:p4"))
})

test("pending permission cards are re-shown after a reconnect", async () => {
	const { emit } = await makePlugin()
	await emit(permission("p5", "s-main"))
	await waitFor(() => daemon.lines.find((l) => l.id === "perm:p5"))
	daemon.closeClients()
	// Give the plugin's close handler an event-loop turn to mark the socket
	// dead, so the next send re-dials instead of writing into a corpse.
	await Bun.sleep(150)
	await emit({
		type: "permission.replied",
		properties: { sessionID: "s-main", permissionID: "unrelated" },
	})
	await waitFor(() => daemon.lines.filter((l) => l.cmd === "show" && l.id === "perm:p5").length === 2)
})
