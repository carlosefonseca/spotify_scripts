#!/usr/bin/env ruby

require 'rspotify'
require 'pry'

class Script

  def env
    @env ||= JSON.load(File.read("env"))
  end

  def initialize
    RSpotify.authenticate(env["client_id"], env["client_secret"])
  end

  def user
    @user ||= RSpotify::User.new options
  end

  def options
    @options = JSON.parse(File.read("token.json"))
  end

  def recent_tracks
    @recents = user.recently_played(limit:50)
  end  

  def run
    playlists_to_modify = ["Drive Mix", "Weekly Playlist", "Mix of Daily Mixes"]
    user.playlists.select { |p| playlists_to_modify.include? p.name }.each { |p| p.remove_tracks! recent_tracks }

    add_tracks_skip_duplicates(recently_played_playlist, recent_tracks)
    trim_playlist(recently_played_playlist, 250)

    plylts = user.playlists.select{|p| playlists_to_modify.include? p.name }.map{|p| [p.name, p.total]}
    plylts += [[recently_played_playlist.name, recently_played_playlist.total]]
    puts plylts.map{|arr|arr.join(": ")}.join(" | ")

    # binding.pry
  end

  def print_playlists
    puts user.playlists.map{|p|[p.uri, p.name].join(" ")}
  end

  def playlist_by_name(name)
    user.playlists.find{|p|   p.name == "Recently Played"}
  end

  def recently_played_playlist
    def fetch_recently_played_playlist
      p = user.playlists.find{|p|   p.name == "Recently Played"}
      p = user.create_playlist!("Recently Played") unless p
      return p
    end
    @recently_played_playlist ||= fetch_recently_played_playlist
  end

  def log_recently_played_tracks
    add_tracks_skip_duplicates(recently_played_playlist, recent_tracks)
  end

  def add_tracks_skip_duplicates(playlist, tracks) # limited to 100 or maybe less
    existing = load_all_tracks(playlist).map(&:uri)
    new_tracks = tracks.reject{|t| existing.include? t.uri}
    playlist.add_tracks!(new_tracks, position:0) unless new_tracks.empty?
  end

  def print_tracks(tracks)
    puts tracks.map{|t|[t.uri, t.name, t.artists.map{|a| a.name}].join(" - ")}
  end

  def p(tracks)
    print_tracks(tracks)
  end

  def load_all_tracks(playlist)
    tracks = []
    while true
      new_tracks = playlist.tracks(offset:tracks.length)
      tracks += new_tracks
      return tracks if new_tracks.empty?
    end
    tracks
  end

  def trim_playlist(playlist, limit)
    tracks_to_remove = (limit..playlist.total).map{|i|i}
    playlist.remove_tracks!(tracks_to_remove) unless tracks_to_remove.empty?
  end

  def dedup(playlist)
    tracks = load_all_tracks(playlist)

    ideal_tracks = tracks.each_with_index.uniq { |t, i| t.uri }.map{|t,i|i}

    to_remove = tracks.each_with_index.reject{|t,i| ideal_tracks.include? i }.map { |t,i| {track: t, positions: [i]} }

    remove(playlist, to_remove)
  end


  def action_each(tracks)
    tracks.each_slice(100).map { |arr| yield arr }
  end

  def remove(playlist, to_remove)
    action_each(to_remove) do |arr|
      playlist.remove_tracks! arr
    end
  end

end

if __FILE__ == $0

  Script.new.run

end
