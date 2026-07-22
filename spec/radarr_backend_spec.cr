require "./spec_helper"

describe ArrTop::RadarrBackend do
  describe ".map_row" do
    it "maps a fully-populated Radarr queue record onto a QueueRow" do
      record = Radarr::Model::QueueResource.from_json(<<-JSON)
        {
          "id": 99,
          "movieId": 5,
          "movie": {"id": 5, "path": "/movies/Some Movie (2026)", "title": "Some Movie"},
          "title": "Some.Movie.2026",
          "size": 2000.0,
          "sizeleft": 500.0,
          "timeleft": "00:05:00",
          "estimatedCompletionTime": "2026-07-18T14:00:00Z",
          "status": "downloading",
          "trackedDownloadState": "importPending",
          "trackedDownloadStatus": "ok",
          "downloadId": "FEDCBA9876543210",
          "downloadClient": "My qbittorrent",
          "protocol": "usenet",
          "indexer": "Movie Indexer"
        }
        JSON

      row = ArrTop::RadarrBackend.map_row(record, "Radarr")
      row.backend_name.should eq("Radarr")
      row.media_kind.should eq(:movie)
      row.title.should eq("Some.Movie.2026")
      row.media_name.should eq("Some Movie")
      row.state.should eq(ArrTop::State::ImportPending)
      row.warning?.should be_false
      row.size.should eq(2000_i64)
      row.size_left.should eq(500_i64)
      row.import_target.should eq(2000_i64)
      row.download_percent.should eq(75.0)
      row.timeleft.should eq("00:05:00")
      row.eta.should eq(Time.utc(2026, 7, 18, 14, 0, 0))
      row.protocol.should eq("usenet")
      row.download_client.should eq("My qbittorrent")
      row.download_id.should eq("FEDCBA9876543210")
      row.indexer.should eq("Movie Indexer")
      row.dest_folder.should eq("/movies/Some Movie (2026)")
    end

    it "flags a warning when trackedDownloadStatus is error" do
      record = Radarr::Model::QueueResource.from_json(
        %({"id": 1, "trackedDownloadStatus": "error"}))
      ArrTop::RadarrBackend.map_row(record, "Radarr").warning?.should be_true
    end
  end
end
