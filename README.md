<p align="center">
  <img src="/docs/header.png" alt="Calendar Sync" />
</p>

# Calendar Sync for macOS

I had the issue that I am using google calendar for my personal calendar while needing to keep my work calendar in a microsoft account up to date. This little Vibe coded app does the job for me.

It is a macOS menu bar app, that uses the calendar framework to sync events between multiple calendars. You can setup multiple syncs, with different filters and time windows.

Feel free to clone the code and build it after installing xcode and running the `./build.sh` script.

<p align="center">
  <img src="/docs/example.png" alt="Calendar Sync Settings" />
</p>

## Features

- One-way sync from source → target calendar
- Recurrence + exceptions with per-occurrence mapping
- Filters: include/exclude, regex, ignore other tuples
- Weekday/time windows; blocker-only mode
- Safe tagging in notes/url plus SwiftData mapping table
- Diagnostics logs (levels), filter and export (JSON/Text)
- Scheduler with configurable interval; manual Sync Now
- Run at Login toggle

## Troubleshooting

You need to give the app the permissions to access your calendar. After this the app should restart.
If it doesn't restart, you need to manually restart it.

## License

MIT
