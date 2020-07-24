#!/usr/bin/env ruby

require 'rspotify'
require 'pry'

class Script

  def env
    @env ||= JSON.load(File.read("env"))
  end

  def initialize(verbose: false)
    @verbose = verbose
    RSpotify.authenticate(env["client_id"], env["client_secret"])
  end

  def user
    @user ||= RSpotify::User.new options
  end

  def options
    @options = JSON.parse(File.read("token.json"))
  end

  def recent_tracks
    def fetch_recent_tracks
      recents = user.recently_played(limit:50)
      if @verbose
        puts "Recent Tracks:"
        p(recents)
      end
      recents
    end

    @recents ||= fetch_recent_tracks
  end  

  def run
    playlists_to_modify = ["Drive Mix", "Weekly Playlist", "Mix of Daily Mixes", "Home Mix"]
    user.playlists.select { |p| playlists_to_modify.include? p.name }.each { |p| remove_tracks_by_metadata(recent_tracks, p) }

    log_recently_played_tracks

    plylts = user.playlists.select{|p| playlists_to_modify.include? p.name }.map{|p| [p.name, p.total]}
    plylts += [[recently_played_playlist.name, recently_played_playlist.total]]
    puts plylts.map{|arr|arr.join(": ")}.join(" | ")
  end

  def remove_tracks_by_metadata(tracks, playlist)
    all_tracks = load_all_tracks(playlist)
    metadata = tracks.flat_map { |t| [t.external_ids, track_name_artist(t)] }
    matches = all_tracks.select { |t| metadata.include?(t.external_ids) || metadata.include?(track_name_artist(t)) }
    if @verbose
      # pp(metadata) 
      puts "Matched tracks to remove:"
      p(matches)
    end
    playlist.remove_tracks! matches
  end

  def track_name_artist(track)
    "#{track.name} - #{track.artists.map{|a|a.name}.join(", ")}"
  end

  def pry
    binding.pry
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
    add_tracks_replace_duplicates(recently_played_playlist, recent_tracks)
  end

  def add_tracks_replace_duplicates(playlist, tracks)
    # fetch the first 50 tracks (most recently played)
    existing_uris = playlist.tracks.map(&:uri)
    # find the tracks that where not recently played already
    new_tracks = tracks.reject { |t| existing_uris.include? t.uri } 

    return if new_tracks.empty?
    playlist.remove_tracks! new_tracks # remove tracks anywhere in the playlist (played least recently)
    playlist.add_tracks!(new_tracks, position: 0) # add them 
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
