require "./spec_helper"

describe ArrTop::SonarrBackend do
  describe ".map_row" do
    it "maps a fully-populated Sonarr queue record onto a QueueRow" do
      record = Sonarr::Model::QueueResource.from_json(<<-JSON)
        {
          "id": 42,
          "seriesId": 7,
          "episodeId": 13,
          "seasonNumber": 2,
          "episodeHasFile": false,
          "episode": {"id": 13, "seasonNumber": 2, "episodeNumber": 3, "title": "The Episode"},
          "series": {"id": 7, "path": "/tv/Some Show", "title": "Some Show"},
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
      row.media_name.should eq("Some Show S02E03")
      row.season_number.should eq(2)
      row.episode_number.should eq(3)
      row.episode_has_file.should be_false
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
      row.media_name.should be_nil
      row.season_number.should be_nil
      row.episode_number.should be_nil
      row.episode_has_file.should be_nil
      row.warning?.should be_false
      row.size.should eq(0_i64)
      row.size_left.should eq(0_i64)
      row.import_target.should eq(0_i64)
      row.download_percent.should eq(0.0)
      row.dest_folder.should be_nil
      row.eta.should be_nil
    end

    it "falls back to the series title when season/episode are unknown" do
      record = Sonarr::Model::QueueResource.from_json(
        %({"id": 1, "title": "x", "series": {"id": 7, "title": "Some Show"}}))
      row = ArrTop::SonarrBackend.map_row(record, "Sonarr")
      row.media_name.should eq("Some Show")
    end
  end

  describe ".episode_media_name" do
    it "appends a zero-padded SxxEyy code when season and episode are known" do
      ArrTop::SonarrBackend.episode_media_name("The Show", 2, 3).should eq("The Show S02E03")
      ArrTop::SonarrBackend.episode_media_name("The Show", 12, 5).should eq("The Show S12E05")
    end

    it "falls back to the series title when season or episode is nil" do
      ArrTop::SonarrBackend.episode_media_name("The Show", nil, 3).should eq("The Show")
      ArrTop::SonarrBackend.episode_media_name("The Show", 2, nil).should eq("The Show")
    end

    it "returns nil when the series title itself is nil" do
      ArrTop::SonarrBackend.episode_media_name(nil, 2, 3).should be_nil
    end
  end
end
