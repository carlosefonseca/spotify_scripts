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
    actual_playlists_to_modify = user.playlists(limit: 50).select { |p| playlists_to_modify.include? p.name }
    playing_playlist_id = currently_playing_playlist.id
    actual_playlists_to_modify.each { |p| remove_tracks_by_metadata(tracks_to_remove, p, playing_playlist_id == p.id) }

    log_recently_played_tracks

    playlists = actual_playlists_to_modify.map { |p| [p.name, p.total] }
    playlists += [[recently_played_playlist.name, recently_played_playlist.total]]
    txt = playlists.map { |arr| arr.join(': ') }.join(' | ')
    puts pastel.green.bold(txt)
  end

  def intersect_track_sets_by_metadata(tracks1, tracks2)
    ids = tracks1.flat_map { |t| [t.id, t.instance_variable_get('@linked_from')&.id].compact }
    external_ids = collect_values(tracks1.map(&:external_ids))
    artist_titles = collect_values(tracks1.map { |t| { t.artists.first.id => t.name.split(' - ').first } })

    artists_to_not_filter_by_track_name = ['25mFVpuABa9GkGcj9eOPce']

    tracks2.select do |t|
      ids.include?(t.id) ||
        ids.include?(t.instance_variable_get('@linked_from')&.id) ||
        external_ids.include?(t.external_ids) ||
        (artists_to_not_filter_by_track_name & t.album.artists.map(&:id)).empty? &&
          (artist_titles[t.artists.first.id] || []).include?(t.name.split(' - ').first)
    end
  end

  def remove_tracks_by_metadata(tracks, playlist, is_playing)
    all_tracks = load_all_tracks(playlist, market: 'from_token')
    matches = intersect_track_sets_by_metadata(tracks, all_tracks)
    unless matches.empty?
      puts pastel.yellow("Matched tracks to remove from #{playlist.name}:")
      p(matches)
    end

    # puts "CEF: is_playing? #{playlist.name} #{is_playing}"
    if is_playing
      first_tracks_on_playlist = all_tracks[0..10]
      # puts "CEF: first_tracks_on_playlist #{first_tracks_on_playlist.map(&:name).join(', ')}"
      first_matches = matches & first_tracks_on_playlist
      # puts "CEF: first_matches #{first_matches.map(&:name).join(', ')}"
      unless first_matches.empty?
        first_index = first_matches.map { |t| first_tracks_on_playlist.index(t) }.min
        tracks_to_prepend = first_tracks_on_playlist[0...first_index]
        matches = tracks_to_prepend + matches
      end
    end

    remove_by_position(playlist, matches, all_tracks)
  end

  def track_name_artist(track)
    "#{track.name.split(' - ').first} - #{track.artists.map(&:name).join(', ')}"
  end

  def pry
    @verbose = true
    binding.pry(quiet: true)
  end

  def print_playlists
    puts(user.playlists.map { |p| [p.uri, p.name].join(' ') })
  end

  def playlist_by_name(name)
    load_all_playlists.find { |p| p.name == name }
  end

  def recently_played_playlist
    def fetch_recently_played_playlist
      p = user.playlists.find { |p| p.name == 'Recently Played' }
      p ||= user.create_playlist!('Recently Played')
      p
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
      top_limit = [(max + 99), playlist.total - 1].min
      tracks = (max..top_limit).to_a
      if @verbose
        puts "Snapshot: #{playlist.snapshot_id}; Total: #{playlist.total}; #{max..top_limit}; L: #{tracks.length}"
      end
      playlist.remove_tracks!(tracks, snapshot_id: playlist.snapshot_id)
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
    tracks_str = tracks.map do |t|
      [t.id, pastel.blue(t.name), pastel.cyan(t.artists.map(&:name).join(', '))].join(' - ')
    end
    puts tracks_str
    tracks
  end

  def p(tracks)
    print_tracks(tracks)
  end

  def p2(tracks)
    tracks_str = tracks.map do |t|
      [t.uri,
       t.name,
       t.artists.map(&:name),
       t.external_ids,
       t.linked_from1&.id].compact.join(' - ')
    end
    puts(tracks_str)
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

    ideal_tracks = tracks.each_with_index.uniq { |t, _i| track_name_artist(t) }.map { |_t, i| i }

    to_remove = tracks.each_with_index.reject { |_t, i| ideal_tracks.include? i }

    p(to_remove.map { |t, _i| t }) if @verbose

    to_remove = to_remove.map { |_t, i| i }

    playlist.remove_tracks!(to_remove, snapshot_id: playlist.snapshot_id)
  end

  def action_each(tracks, &block)
    tracks.each_slice(100).to_a.reverse.map(&block)
  end

  def remove_by_position(playlist, to_remove, playlist_tracks = nil)
    playlist_tracks ||= load_all_tracks(playlist)
    action_each(to_remove) do |arr|
      positions = playlist_tracks.each_with_index.select { |e, _i| arr.include? e }.map { |_e, i| i }
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

  def device(name)
    device = user.devices.find { |d| d.name == name }
    raise "#{name} not found!" unless device

    device
  end

  def zipp
    @zipp ||= device('ZIPP')
  end

  def computer
    @computer ||= user.devices.find { |d| d.name == 'PT-330351-MBP16M1' }
  end

  def play_playlist_on_zipp_named(name)
    play_playlist_on_zipp(playlist_by_name(name).uri)
  end

  def play_playlist_on_zipp(uri)
    # run

    RSpotify.raw_response = true
    data = JSON.load(user.player.body)
    RSpotify.raw_response = false
    playing_uri = data&.dig('context', 'uri')
    is_playing = data&.dig('is_playing')

    # playing_uri = uri_of_currently_playing_context
    if playing_uri == uri
      user.player.play unless user.player.playing?
    else
      user.player.play_context(device_id = zipp.id, uri)
    end
  end

  def resume_zipp
    return if player.device.name == 'ZIPP'

    uid = user.id
    params = { device_ids: [zipp.id], play: true }
    RSpotify::User.oauth_put(uid, 'me/player', params.to_json)
    player.volume 20 # causes the warning
  rescue StandardError => e
    puts "Failed to resume zipp. #{e}\nParams: #{params}"
    exit 1
  ensure
    puts "#{currently_playing_playlist.name}\nVolume: #{user.player.device.volume_percent}%"
  end

  def resume_computer
    uid = user.id
    params = { device_ids: [computer.id], play: true }
    RSpotify::User.oauth_put(uid, 'me/player', params.to_json)
  rescue StandardError => e
    puts "Failed to resume Computer. #{e}\nParams: #{params}"
    exit 1
  ensure
    puts "#{currently_playing_playlist.name}\nVolume: #{user.player.device.volume_percent}%"
  end

  def currently_playing_playlist_uri
    player
    RSpotify.raw_response = true
    r = player.currently_playing
    RSpotify.raw_response = false
    json = JSON.load(r)
    return nil unless json

    json.dig('context', 'uri') if json.dig('context', 'type') == 'playlist'
  end

  def currently_playing_playlist
    playlist_uri = currently_playing_playlist_uri
    RSpotify::Playlist.find_by_id(playlist_uri.split(':').last) if playlist_uri
  end

  def remove_track_from_playing_playlist
    playlist = currently_playing_playlist
    raise "#{playlist.name} is not yours!" if playlist.owner.id != user.id

    track = player.currently_playing
    playlist.remove_tracks!([track], snapshot_id: playlist.snapshot_id)
    player.next
  end
end

def collect_values(hashes)
  {}.tap { |r| hashes.each { |h| h.each { |k, v| (r[k] ||= Set[]) << v } } }
end

if __FILE__ == $PROGRAM_NAME
  quiet = ARGV.delete('--quiet')

  begin
    case ARGV[0]
    when 'resume_zipp'
      Script.new.resume_zipp
    when 'resume_computer'
      Script.new.resume_computer
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
  rescue StandardError => e
    raise e unless quiet

    pastel = Pastel.new
    warn(pastel.red.bold(e))
    exit 1
  end
end
