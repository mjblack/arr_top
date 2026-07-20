require "./spec_helper"

describe ArrTop::SonarrBackend do
  describe ".map_row" do
    it "maps a fully-populated Sonarr queue record onto a QueueRow" do
      record = Sonarr::Model::QueueResource.from_json(<<-JSON)
        {
          "id": 42,
          "seriesId": 7,
          "episodeId": 13,
          "series": {"id": 7, "path": "/tv/Some Show"},
          "title": "Some.Release.Group",
          "size": 1000.0,
          "sizeleft": 250.0,
          "timeleft": "00:12:34",
          "estimatedCompletionTime": "2026-07-18T13:00:00Z",
          "status": "downloading",
          "trackedDownloadState": "importing",
          "trackedDownloadStatus": "warning",
          "downloadId": "ABCDEF0123456789",
          "downloadClient": "My qbittorrent",
          "protocol": "torrent",
          "indexer": "My Indexer"
        }
        JSON

      row = ArrTop::SonarrBackend.map_row(record, "Sonarr")
      row.backend_name.should eq("Sonarr")
      row.media_kind.should eq(:episode)
      row.title.should eq("Some.Release.Group")
      row.state.should eq(ArrTop::State::Importing)
      row.warning?.should be_true
      row.size.should eq(1000_i64)
      row.size_left.should eq(250_i64)
      row.import_target.should eq(1000_i64)
      row.download_percent.should eq(75.0)
      row.timeleft.should eq("00:12:34")
      row.eta.should eq(Time.utc(2026, 7, 18, 13, 0, 0))
      row.protocol.should eq("torrent")
      row.download_client.should eq("My qbittorrent")
      row.download_id.should eq("ABCDEF0123456789")
      row.indexer.should eq("My Indexer")
      row.dest_folder.should eq("/tv/Some Show")
    end

    it "tolerates a sparse record: nil sizes become 0, warning false, dest nil" do
      record = Sonarr::Model::QueueResource.from_json(%({"id": 1, "title": "x"}))
      row = ArrTop::SonarrBackend.map_row(record, "Sonarr")
      row.state.should eq(ArrTop::State::Unknown)
      row.warning?.should be_false
      row.size.should eq(0_i64)
      row.size_left.should eq(0_i64)
      row.import_target.should eq(0_i64)
      row.download_percent.should eq(0.0)
      row.dest_folder.should be_nil
      row.eta.should be_nil
    end
  end
end
