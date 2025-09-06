bash -lc "/Users/keller/repos/calendar-sync/build.sh | cat" && (pkill -x "CalendarSync" || true) && open ./build/Build/Products/Release/CalendarSync.app
