#!/usr/bin/env ruby

# To Do:
# - Cache playlists to avoid doing ~20 requests × N playlists every 30 min.
#   - Store the list of tracks, remove tracks from the cache and the server, compare track count, cache the server's snapshot id
#   - Next run check if the snapshot id is still the same.

require 'rspotify'
require 'pry'
require 'pastel'

module RSpotify
  class User
    def player
      url = 'me/player'
      response = User.oauth_get(@id, url)
      return response if RSpotify.raw_response
      response ? Player.new(self, response) : Player.new(self)
    end
  end
end

module RSpotify
  class Track
    def linked_from1
      instance_variable_get('@linked_from')
    end
  end
end


class Script

  def pastel
    pastel ||= Pastel.new
  end

  def env
    @env ||= JSON.load(File.read('env'))
  end

  def initialize(verbose: false)
    @verbose = verbose
    RSpotify.authenticate(env['client_id'], env['client_secret'])
  end

  def user
    @user ||= RSpotify::User.new options
  end

  def options
    @options = JSON.parse(File.read('token.json'))
  end

  def player
    @player ||= user.player
  end

  def recent_tracks
    def fetch_recent_tracks
      recents = user.recently_played(limit: 50)
      if @verbose
        puts 'Recent Tracks:'
        p(recents)
      end
      recents
    end

    @recents ||= fetch_recent_tracks
  end

  def all_recently_played
    @all_recents ||= load_all_tracks(playlist_by_name('Recently Played'), market: nil)
  end

  def clean
    run(tracks_to_remove: all_recently_played + recent_tracks)
  end

  def run(tracks_to_remove: recent_tracks)
    playlists_to_modify = ['Drive Mix', 'Weekly Playlist', 'Mix of Daily Mixes', 'Home Mix']
    user.playlists(limit:50).select { |p| playlists_to_modify.include? p.name }.each { |p| remove_tracks_by_metadata(tracks_to_remove, p) }

    log_recently_played_tracks

    plylts = user.playlists(limit:50).select { |p| playlists_to_modify.include? p.name }.map { |p| [p.name, p.total] }
    plylts += [[recently_played_playlist.name, recently_played_playlist.total]]
    txt = plylts.map { |arr| arr.join(': ') }.join(' | ')
    puts pastel.green.bold(txt)
  end

  def intersect_track_sets_by_metadata(tracks1, tracks2)
    ids = tracks1.flat_map { |t| [t.id, t.instance_variable_get('@linked_from')&.id].compact }
    external_ids = collect_values(tracks1.map { |t| t.external_ids })
    artistTitles = collect_values(tracks1.map { |t| { t.artists.first.id => t.name.split(' - ').first } })

    artistsToNotFilterByTrackName = ['25mFVpuABa9GkGcj9eOPce']

    tracks2.select do |t|
      ids.include?(t.id) ||
      ids.include?(t.instance_variable_get('@linked_from')&.id) ||
      external_ids.include?(t.external_ids) ||
      ((artistsToNotFilterByTrackName & t.album.artists.map { |a| a.id }).empty?) && ((artistTitles[t.artists.first.id] || []).include?(t.name.split(' - ').first))
    end
  end

  def remove_tracks_by_metadata(tracks, playlist)
    all_tracks = load_all_tracks(playlist, market: 'from_token')
    matches = intersect_track_sets_by_metadata(tracks, all_tracks)
    if !matches.empty?
      puts pastel.yellow("Matched tracks to remove from #{playlist.name}:")
      p(matches)
    end
    remove_by_position(playlist, matches, all_tracks)
  end

  def track_name_artist(track)
    "#{track.name.split(' - ').first} - #{track.artists.map { |a| a.name }.join(', ')}"
  end

  def pry
    @verbose = true
    binding.pry(quiet: true)
  end

  def print_playlists
    puts user.playlists.map { |p| [p.uri, p.name].join(' ') }
  end

  def playlist_by_name(name)
    load_all_playlists.find { |p| p.name == name }
  end

  def recently_played_playlist
    def fetch_recently_played_playlist
      p = user.playlists.find { |p| p.name == 'Recently Played' }
      p = user.create_playlist!('Recently Played') unless p
      return p
    end

    @recently_played_playlist ||= fetch_recently_played_playlist
  end

  def log_recently_played_tracks
    add_tracks_replace_duplicates(recently_played_playlist, recent_tracks)
    trim_playlist(recently_played_playlist)
  end

  def trim_playlist(playlist)
    max = 2000
    playlist.complete!
    while playlist.total > max
      top_limit = [(max+99), playlist.total - 1].min
      trks = (max..top_limit).to_a
      puts "Snapshot: #{playlist.snapshot_id}; Total: #{playlist.total}; #{(max..top_limit)}; L: #{trks.length}" if @verbose
      playlist.remove_tracks!(trks, snapshot_id: playlist.snapshot_id)
      playlist.complete!
    end
  end

  def add_tracks_replace_duplicates(playlist, tracks)
    # fetch the first 50 tracks (most recently played)
    existing_uris = playlist.tracks(market: 'from_token').map(&:uri)
    # find the tracks that were not recently played already
    new_tracks = tracks.reject { |t| existing_uris.include? t.uri }

    return if new_tracks.empty?
    playlist.remove_tracks! new_tracks # remove tracks anywhere in the playlist (played least recently)
    playlist.add_tracks!(new_tracks, position: 0) # add them
  end

  def add_tracks_skip_duplicates(playlist, tracks) # limited to 100 or maybe less
    existing = load_all_tracks(playlist).map(&:uri)
    new_tracks = tracks.reject { |t| existing.include? t.uri }
    playlist.add_tracks!(new_tracks, position: 0) unless new_tracks.empty?
  end

  def print_tracks(tracks)
    puts tracks.map { |t| [t.id, pastel.blue(t.name), pastel.cyan(t.artists.map { |a| a.name }.join(', '))].join(' - ') }
    tracks
  end

  def p(tracks)
    print_tracks(tracks)
  end

  def p2(tracks)
    puts tracks.map { |t| [t.uri, t.name, t.artists.map { |a| a.name }, t.external_ids, t.linked_from1&.id].compact.join(' - ') }
    tracks
  end

  def load_all_tracks(playlist, market: 'from_token')
    tracks = []
    while true
      new_tracks = playlist.tracks(offset: tracks.length, market: market)
      tracks += new_tracks
      return tracks if new_tracks.empty?
    end
    tracks
  end

  def load_all_playlists
    def _load
      playlists = []
      while true
        new_playlists = user.playlists(limit: 50, offset: playlists.length)
        playlists += new_playlists
        return playlists if new_playlists.empty?
      end
    end

    @playlists ||= _load
  end

  def load_saved_tracks(market: 'from_token')
    tracks = []
    while true
      new_tracks = user.saved_tracks(offset: tracks.length, market: market)
      tracks += new_tracks
      return tracks if new_tracks.empty?
    end
    tracks
  end

  def dedup(playlist)
    tracks = load_all_tracks(playlist)

    ideal_tracks = tracks.each_with_index.uniq { |t, i| track_name_artist(t) }.map { |t, i| i }

    to_remove = tracks.each_with_index.reject { |t, i| ideal_tracks.include? i }

    p(to_remove.map { |t, i| t }) if @verbose

    to_remove = to_remove.map { |t, i| i }

    playlist.remove_tracks!(to_remove, snapshot_id: playlist.snapshot_id)
  end

  def action_each(tracks)
    tracks.each_slice(100).to_a.reverse.map { |arr| yield arr }
  end

  def remove_by_position(playlist, to_remove, playlist_tracks = nil)
    playlist_tracks ||= load_all_tracks(playlist)
    action_each(to_remove) do |arr|
      positions = playlist_tracks.each_with_index.select { |e, i| arr.include? e }.map { |e, i| i }
      playlist.remove_tracks!(positions, snapshot_id: playlist.snapshot_id)
    end
  end

  def remove(playlist, to_remove)
    action_each(to_remove) do |arr|
      playlist.remove_tracks! arr
    end
  end

  def play_playlist_on_device(playlist_name, device_name)
    p = playlist_by_name playlist_name
    d = user.devices.find { |d| d.name == device_name }
    user.player.play_context(device_id = d.id, p.uri)
  end

  def zipp
    @zipp ||= user.devices.find { |d| d.name == 'ZIPP' }
  end

  def play_playlist_on_zipp_named(name)
    play_playlist_on_zipp(playlist_by_name(name).uri)
  end

  def play_playlist_on_zipp(uri)
    run

    RSpotify.raw_response = true
    data = JSON.load(user.player.body)
    RSpotify.raw_response = false
    playing_uri = data&.dig('context', 'uri')
    is_playing = data&.dig('is_playing')

    # playing_uri = uri_of_currently_playing_context
    if playing_uri == uri
      unless user.player.playing?
        user.player.play
      end
    else
      user.player.play_context(device_id = zipp.id, uri)
    end
  end

  def resume_zipp
    begin
      uid = user.id
      params = { device_ids: [zipp.id], play: true }
      RSpotify::User.oauth_put(uid, 'me/player', params.to_json)
    rescue => exception
      raise "Failed to resume zipp. Params: #{params}"
    end
    puts get_currently_playing_playlist.name
  end

  def currently_playing_playlist_uri
    player
    RSpotify.raw_response = true
    r = player.currently_playing
    RSpotify.raw_response = false
    json = JSON.load(r)
    if json.dig('context', 'type') == "playlist"
      json.dig('context', 'uri')
    else
      nil
    end
  end
  
  def get_currently_playing_playlist
    playlist_uri = currently_playing_playlist_uri
    RSpotify::Playlist.find_by_id(playlist_uri.split(":").last)
  end

  def remove_track_from_playing_playlist
    playlist = get_currently_playing_playlist
    raise "#{playlist.name} is not yours!" if playlist.owner.id != user.id
    track = player.currently_playing
    playlist.remove_tracks!([track], snapshot_id: playlist.snapshot_id)
    player.next
  end
end

def collect_values(hashes)
  {}.tap { |r| hashes.each { |h| h.each { |k, v| (r[k] ||= Set[]) << v } } }
end

if __FILE__ == $0
  quiet = ARGV.delete("--quiet")

  begin
    case ARGV[0]
    when 'resume_zipp'
      Script.new.resume_zipp
    when 'zipp_weekly_playlist'
      Script.new.play_playlist_on_zipp('spotify:playlist:7oorBA7hnNJngmox1JNrGW')
    when 'zipp_home'
      Script.new.play_playlist_on_zipp('spotify:playlist:20IsQZexWUDfjim8Xn3g52')
    when 'zipp_playlist'
      Script.new.play_playlist_on_zipp_named('Drive Mix')
    when 'clean'
      Script.new.clean
    when 'dedup'
      script = Script.new(verbose: true)
      script.dedup(script.playlist_by_name(ARGV[1]))
    when 'remove_current_track'
      Script.new.remove_track_from_playing_playlist
    when 'pry'
      Script.new.pry
    else
      Script.new.run
    end
  rescue => exception
    if quiet
      pastel = Pastel.new
      STDERR.puts(pastel.red.bold(exception))
      exit 1
    else
      raise exception
    end
  end
end
