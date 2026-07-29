import { existsSync } from "node:fs"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { type Plugin } from "@opencode-ai/plugin"

// Escape a string for use inside an AppleScript double-quoted literal.
const esc = (s: string) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')

const notch = join(dirname(fileURLToPath(import.meta.url)), "..", "swift", "notch.app")

export const NotchPlugin: Plugin = async ({ client, $, directory }) => {
	const title = basename(directory) || "opencode"
	let last = 0
	return {
		event: async ({ event }) => {
			if (event.type !== "session.idle") return
			const now = Date.now()
			if (now - last < 4500) return // debounce: the pill is visible ~3.5s
			try {
				const session = await client.session.get({ path: { id: event.properties.sessionID } })
				// Skip subagent (child) sessions; only notify when the main session finishes.
				if (!session.data || session.data.parentID) return
				last = now
				const body = session.data.title || "Response ready"
				const files = session.data.summary?.files ?? 0
				const additions = session.data.summary?.additions ?? 0
				const deletions = session.data.summary?.deletions ?? 0
				if (existsSync(notch)) {
					// LaunchServices honors LSUIElement; -g prevents foreground activation.
					$`open -g -n ${notch} --args ${title} ${body} ${files} ${additions} ${deletions}`
						.quiet()
						.nothrow()
						.catch(() => {})
				} else {
					// Binary not built; fall back to a standard notification.
					const script = `display notification "${esc(body)}" with title "${esc(title)}" sound name "Glass"`
					await $`osascript -e ${script}`
				}
			} catch {
				// A failed notification must never break the event bus.
			}
		},
	}
}

export default NotchPlugin
