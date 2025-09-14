<p align="center">
  <img src="/docs/header.png" alt="Calendar Sync" />
</p>

# Calendar Sync for macOS

I had the issue that I am using google calendar for my personal calendar while needing to keep my work calendar in a microsoft account up to date. This little Vibe coded app does the job for me.

It is a macOS menu bar app, that uses the calendar framework to sync events between multiple calendars. You can setup multiple syncs, with different filters and time windows.

Feel free to clone the code and build it after installing xcode and running the `./install.sh` script or download the latest release from the [releases page](https://github.com/kellerh/calendar-sync/releases).

This app is vibe-coded - use at your own risk.

<p align="center">
  <img src="/docs/example.png" alt="Calendar Sync Settings" />
</p>

## Features

- One-way sync from source → target calendar
- Recurrence + exceptions with per-occurrence mapping
- Filters: include/exclude, regex, ignore other tuples
- Weekday/time windows; blocker-only mode
- Tagging in Event Notes for safe sync even from multiple computers
- Diagnostics logs (levels), filter and export (JSON/Text)
- Scheduler with configurable interval; manual Sync Now
- Run at Login toggle

## Running on multiple computers

If you want to run the app on multiple computers, make sure that you export the settings and import them on the other computers. The explicit IDs from the sync tuples are used to identify the events and align them to the correct events on the other computers.

## Troubleshooting

You need to give the app the permissions to access your calendar. After this the app should restart. If it doesn't restart, you need to manually restart it.

## License

MIT
