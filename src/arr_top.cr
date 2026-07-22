require "sonarr"
require "radarr"

# arrtop — a top-like terminal UI for the Sonarr/Radarr download + import
# pipeline. It reads the *arr queue (typed, via the `sonarr`/`radarr` shards),
# sorts by what's actively importing, and renders progress bars — including
# import (copy) progress the *arr API does not report, read from the destination
# file on disk. That disk read means arrtop is meant to run **on the *arr host**.
module ArrTop
  VERSION = "0.3.0"
end

# Components are picked up automatically — drop new files into src/arr_top/.
require "./arr_top/**"
