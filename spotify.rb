#!/usr/bin/env ruby
# frozen_string_literal: true

# To Do:
# - Cache playlists to avoid doing ~20 requests × N playlists every 30 min.
# rubocop:todo Layout/LineLength
#   - Store the list of tracks, remove tracks from the cache and the server, compare track count, cache the server's snapshot id
# rubocop:enable Layout/LineLength
#   - Next run check if the snapshot id is still the same.

require 'rspotify'
require 'pry'
require 'pastel'
require 'rest-client'
require 'tty-prompt'

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
  # Extension
  class Track
    def linked_from1
      instance_variable_get('@linked_from')
    end
  end
end

# Main Script Class
class Script
  def pastel
    pastel ||= Pastel.new
  end

  def env
    @env ||= JSON.parse(File.read('env'))
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
    fetch_recent_tracks = lambda {
      recents = user.recently_played(limit: 50)
      if @verbose
        puts 'Recent Tracks:'
        p(recents)
      end
      recents
    }

    @recent_tracks ||= fetch_recent_tracks.call
  end

  def all_recently_played
    @all_recents ||= load_all_tracks(playlist_by_name('Recently Played'), market: nil)
  end

  def clean
    run(tracks_to_remove: all_recently_played + recent_tracks)
  end

  def create_playlist_version_without_recently_played(playlist)
    tracks = load_all_tracks(playlist)
    new_tracks = subtract_track_sets_by_metadata(all_recently_played, tracks)
    new_playlist_name = playlist.name + ' (Without Recents)'
    new_playlist = playlist_by_name(new_playlist_name) || user.create_playlist!(new_playlist_name)
    replace_all_tracks_on_playlist(new_tracks, new_playlist)
    new_playlist
  end

  def run(tracks_to_remove: recent_tracks)
    # playlists_to_modify = ['Together Mega Mix', 'Weekly Playlist', 'Mix of Daily Mixes', 'Home Mix']
    playlists_to_modify = ['Together Mega Mix']
    actual_playlists_to_modify = playlists_to_modify.map { |name| playlist_by_name(name) }.compact
    playing_playlist_id = currently_playing_playlist&.id
    actual_playlists_to_modify.each { |p| remove_tracks_by_metadata(tracks_to_remove, p, playing_playlist_id == p.id) }

    log_recently_played_tracks

    playlists = actual_playlists_to_modify.map { |p| [p.name, p.total] }
    playlists += [[recently_played_playlist.name, recently_played_playlist.total]]
    txt = playlists.map { |arr| arr.join(': ') }.join(' | ')
    puts pastel.green.bold(txt)
  end

  def intersect_track_sets_by_metadata(tracks1, tracks2) # rubocop:todo Metrics/CyclomaticComplexity, Metrics/AbcSize, Metrics/PerceivedComplexity
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

  def subtract_tracks_by_metadata(tracks1, tracks2)
    ids = tracks2.flat_map { |t| [t.id, t.instance_variable_get('@linked_from')&.id].compact }
    external_ids = collect_values(tracks2.map(&:external_ids))
    artist_titles = collect_values(tracks2.map { |t| { t.artists.first.id => t.name.split(' - ').first } })
    artists_to_not_filter_by_track_name = ['25mFVpuABa9GkGcj9eOPce']
    tracks1.reject do |t|
      ids.include?(t.id) ||
        ids.include?(t.instance_variable_get('@linked_from')&.id) ||
        external_ids.include?(t.external_ids) ||
        (artists_to_not_filter_by_track_name & t.album.artists.map(&:id)).empty? &&
          (artist_titles[t.artists.first.id] || []).include?(t.name.split(' - ').first)
    end
  end

  def remove_tracks_by_metadata(tracks, playlist, is_playing) # rubocop:todo Metrics/AbcSize
    all_tracks = load_all_tracks(playlist, market: nil)
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
    binding.pry(quiet: true) # rubocop:todo Lint/Debugger
  end

  def print_playlists
    puts(user.playlists.map { |p| [p.uri, p.name].join(' ') })
  end

  def playlist_by_name(name)
    playlists.find { |p| p.name == name }
  end

  def id_of_uri(uri)
    uri.split(':').last
  end

  def playlist_by_uri(uri)
    puts "playlist_by_uri: #{uri}" if @verbose
    id = id_of_uri(uri)
    RSpotify::Playlist.find_by_id(id)
  end

  def get_playlist(input)
    if input == 'current'
      return currently_playing_playlist if currently_playing_playlist

      raise 'No currently playing playlist found!'
    end

    if input == 'recents'
      return recently_played_playlist if recently_played_playlist

      raise 'No recently played playlist found!'
    end

    if input.start_with?('https://open.spotify.com/playlist/')
      input = 'spotify:playlist:' + uri.split('/').last.split('?').first
    end

    if input.start_with?('spotify:playlist:')
      playlist_by_uri(input)
    else
      playlist_by_name(input)
    end
  end

  def recently_played_playlist
    @recently_played_playlist ||= playlist_by_uri('spotify:playlist:0UmRcaAtlntTFAxq0vHH3r')
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
    existing_uris = playlist.tracks(market: nil).map(&:uri)
    # find the tracks that were not recently played already
    new_tracks = tracks.reject { |t| existing_uris.include? t.uri }

    return if new_tracks.empty?

    playlist.remove_tracks! new_tracks # remove tracks anywhere in the playlist (played least recently)
    playlist.add_tracks!(new_tracks, position: 0) # add them
  end

  # limited to 100 or maybe less
  def add_tracks_skip_duplicates(playlist, tracks)
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

  def load_all_tracks(playlist, market: nil)
    tracks = []
    loop do
      new_tracks = playlist.tracks(offset: tracks.length, market: market)
      tracks += new_tracks
      return tracks if new_tracks.empty?
    end
    tracks
  end

  def playlists
    @playlists ||= load_all_playlists
  end

  def load_all_playlists
    def _load # rubocop:todo Lint/NestedMethodDefinition
      playlists = []
      loop do
        new_playlists = user.playlists(limit: 50, offset: playlists.length)
        playlists += new_playlists
        return playlists if new_playlists.empty?
      end
    end

    @playlists ||= _load
  end

  def load_saved_tracks(market: nil)
    tracks = []
    loop do
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

  def clear_playlist(playlist)
    playlist_tracks ||= load_all_tracks(playlist)
    action_each(playlist_tracks) do |arr|
      positions = playlist_tracks.each_with_index.select { |e, _i| arr.include? e }.map { |_e, i| i }
      playlist.remove_tracks!(positions, snapshot_id: playlist.snapshot_id)
    end
  end

  def add_tracks_to_playlist(tracks, playlist)
    action_each(tracks) do |section|
      playlist.add_tracks! section
    end
  end

  def replace_all_tracks_on_playlist(tracks, playlist)
    clear_playlist(playlist)
    clear_playlist(playlist)
    playlist.complete!
    add_tracks_to_playlist(tracks, playlist)
  end

  def save_tracks_to_playlist_named(new_playlist_name, tracks)
    new_playlist = playlist_by_name(new_playlist_name) || user.create_playlist!(new_playlist_name)
    clear_playlist(new_playlist)
    add_tracks_to_playlist(tracks, new_playlist)
    new_playlist
  end

  def remove(playlist, to_remove)
    action_each(to_remove) do |arr|
      playlist.remove_tracks! arr
    end
  end

  def play_playlist_on_device(playlist_name, device_name)
    p = playlist_by_name playlist_name
    d = user.devices.find { |d| d.name == device_name } # rubocop:todo Lint/ShadowingOuterLocalVariable
    user.player.play_context(device_id = d.id, p.uri) # rubocop:todo Lint/UselessAssignment
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
    @computer ||= user.devices.find { |d| d.name == `hostname`.strip.delete_suffix('.local') }
  end

  def play_playlist_on_zipp_named(name)
    play_playlist_on_zipp(playlist_by_name(name).uri)
  end

  def play_playlist_on_zipp(uri, shuffle: nil) # rubocop:todo Metrics/AbcSize
    # run

    data = nil
    RSpotify.raw_response = true
    begin
      data = JSON.parse(user.player.body)
    rescue StandardError
    end
    RSpotify.raw_response = false
    playing_uri = data&.dig('context', 'uri')
    is_playing = data&.dig('is_playing') # rubocop:todo Lint/UselessAssignment

    # playing_uri = uri_of_currently_playing_context
    if playing_uri == uri
      user.player.play unless user.player.playing?
    else
      user.player.shuffle(device_id: zipp.id, state: shuffle) unless shuffle.nil?
      user.player.play_context(device_id = zipp.id, uri) # rubocop:todo Lint/UselessAssignment
    end
    player.volume 10 # causes the warning
  end

  def resume_zipp # rubocop:todo Metrics/AbcSize
    unless player.is_playing
      puts 'Nothing is playing.'
      exit 1
    end

    begin
      return if player.device.name == 'ZIPP'

      uid = user.id
      params = { device_ids: [zipp.id], play: true }
      RSpotify::User.oauth_put(uid, 'me/player', params.to_json)

      puts "Player: #{user.player}"
      puts "Playing: #{user.player.playing?}"
      puts "Device: #{user.player.device}"

      until user.player && user.player.device
        puts 'Sleeping...'
        sleep(0.1)
      end
      player.volume 10 # causes the warning
    rescue StandardError => e
      puts "Failed to resume zipp. #{e}\nParams: #{params}"
      exit 1
    ensure
      puts "#{currently_playing_playlist&.name}\nVolume: #{user.player.device.volume_percent}%"
    end
  end

  def resume_computer
    uid = user.id
    params = { device_ids: [computer.id], play: true }
    RSpotify::User.oauth_put(uid, 'me/player', params.to_json)
    until user.player && user.player.device
      puts 'Sleeping...'
      sleep(0.1)
    end
    user.player.volume(50)
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
    return nil if r == ''

    json = JSON.parse(r)
    return nil unless json

    json.dig('context', 'uri') if json.dig('context', 'type') == 'playlist'
  end

  def currently_playing_playlist
    playlist_uri = currently_playing_playlist_uri
    playlist_by_uri(playlist_uri) if playlist_uri
  end

  def remove_track_from_playing_playlist
    playlist = currently_playing_playlist
    raise "#{playlist.name} is not yours!" if playlist.owner.id != user.id

    track = player.currently_playing
    playlist.remove_tracks!([track], snapshot_id: playlist.snapshot_id)
    player.next
  end

  def playlist_lyrics(id)
    playlist_id = id_of_uri(id)
    p = RSpotify::Playlist.find_by_id(playlist_id)
    tracks = p.tracks
    p(tracks)
    lyrics_for_tracks(tracks)
  end

  def lyrics_for_tracks(tracks)
    tracks.map do |t|
      artist = t.artists.first.name
      name = t.name
      name_artist = "#{artist} - #{name}"
      puts "# #{name_artist}"
      puts ''
      lyrics = get_lyrics(name, artist)
      if lyrics
        puts lyrics
        puts ''
        [name_artist, lyrics]
      else
        puts 'N/A'
        puts ''
        [name_artist, 'FAIL']
      end
    end
  end

  def request_song_info(track_name, track_artist)
    require 'addressable/template'
    template = Addressable::Template.new('https://api.genius.com/search{?query*}')
    url = template.expand({ query: { q: "#{track_name} #{track_artist}" } }).to_s

    genius_key = 'zJDhrTb_AArfagDUbwjG5BXLmXNLz507-b85VPeFVvbCwFhyPxNCTVBpOufIDdbC'
    headers = { 'Authorization': "Bearer #{genius_key}" }

    RestClient.get(url, headers)
  end

  def check_hits(track_name, track_artist)
    response = request_song_info(track_name, track_artist)

    json = JSON.parse(response.body)
    json['response']['hits'].each do |hit|
      return hit if hit['result']['primary_artist']['name'].downcase.include? track_artist.downcase
    end
    nil
  end

  def get_lyrics(track_name, track_artist)
    hit = check_hits(track_name, track_artist)
    return nil unless hit

    hit_url = hit.dig('result', 'url')
    scrape_lyrics(hit_url)
  end

  def scrape_lyrics(url)
    require 'nokogiri'

    page = RestClient.get(url).body

    html = Nokogiri::HTML(page)

    lyrics_container = html.at_xpath("//div[@data-lyrics-container='true']")

    return nil unless lyrics_container

    lyrics_container.xpath('.//br').each do |br_tag|
      br_tag.replace("\n")
    end

    lyrics_container.text
  end

  def check_playlist_name_changes(playlists)
    relevant_playlists = user.playlists(limit: 10).select { |p| playlists.include? p.id }
    puts relevant_playlists.map(&:name).join(', ')
  end

  def import(artist, tracks)
    require 'tty-table'
    table = TTY::Table.new(header: %w[Search Match])

    tracks_str = tracks.map do |t|
    end
    puts tracks_str

    found_tracks = tracks.flat_map do |t|
      search = "#{artist} - #{t}"
      puts search
      track = RSpotify::Track.search(search, limit: 1)[0]
      track_str = [track.name, track.artists.map(&:name).join(', ')].join(' - ')
      table << [search, track_str]
      track
    end

    puts table.render(:unicode)

    playlist = user.create_playlist!("#{artist} import")
    playlist.add_tracks!(found_tracks)
    puts playlist.uri
    playlist
  end

  def shuffle_run_mad
    rm1 = playlist_by_name('run mad')
    rm2 = playlist_by_name('run mad 2')
    srm = playlist_by_name('Shuffle Run Mad')
    shuffle = (rm1.tracks + rm2.tracks).shuffle
    replace_all_tracks_on_playlist(shuffle, srm)
  end

  def shuffle_playlist(playlist: nil, playlist_name: nil, playlist_uri: nil)
    playlist = playlist || playlist_by_name(playlist_name) || playlist_by_uri(playlist_uri)
    tracks = load_all_tracks(playlist, market: nil)
    shuffle = tracks.shuffle
    replace_all_tracks_on_playlist(shuffle, playlist)
  end

  def playlist_without_playlist(p1, p2, shuffle: false)
    tracks1 = load_all_tracks(p1, market: nil)
    tracks2 = load_all_tracks(p2, market: nil)
    tracks = subtract_tracks_by_metadata(tracks1, tracks2)
    tracks = tracks.shuffle if shuffle
    save_tracks_to_playlist_named("#{p1.name} without #{p2.name}", tracks)
  end

  def select_saved_tracks(tracks)
    tracks.each_slice(50).to_a.flat_map do |a|
      result = user.saved_tracks? a
      a.zip(result).select { |_, r| r }.map(&:first)
    end
  end

  def select_not_saved_tracks(tracks)
    tracks.each_slice(50).to_a.flat_map do |a|
      result = user.saved_tracks? a
      a.zip(result).reject { |_, r| r }.map(&:first)
    end
  end

  def playlist_without_saved(p1, shuffle: false)
    tracks1 = load_all_tracks(p1, market: nil)
    tracks2 = select_not_saved_tracks(tracks1)
    tracks2 = tracks2.shuffle if shuffle
    save_tracks_to_playlist_named("#{p1.name} (not saved)", tracks2)
  end

  def split_run_mad_master
    # Load the Run Mad Master playlist
    master_playlist = playlist_by_uri('spotify:playlist:0ij4iUFJ1OJTA4fvYnnSEL')
    puts "Loading tracks from #{master_playlist.name}..."
    all_tracks = load_all_tracks(master_playlist, market: nil)
    puts "Total tracks: #{all_tracks.length}"

    # Split tracks into chunks of 100
    track_chunks = all_tracks.each_slice(100).to_a
    puts "Creating #{track_chunks.length} playlists..."

    # Create or replace _runmad_1, _runmad_2, etc.
    track_chunks.each_with_index do |chunk, index|
      playlist_name = "_runmad_#{index + 1}"
      puts "Processing #{playlist_name} with #{chunk.length} tracks..."

      # Find existing playlist or create new one
      existing_playlist = playlist_by_name(playlist_name)
      if existing_playlist
        puts "Replacing existing playlist: #{playlist_name}"
        replace_all_tracks_on_playlist(chunk, existing_playlist)
      else
        puts "Creating new playlist: #{playlist_name}"
        new_playlist = user.create_playlist!(playlist_name)
        add_tracks_to_playlist(chunk, new_playlist)
      end
    end

    # Create shuffled 100-song playlist from the master
    shuffled_tracks = all_tracks.sample(100)
    shuffled_playlist_name = '_runmad_shuffle'
    puts "Creating shuffled playlist: #{shuffled_playlist_name} with 100 tracks..."

    existing_shuffle = playlist_by_name(shuffled_playlist_name)
    if existing_shuffle
      puts 'Replacing existing shuffled playlist'
      replace_all_tracks_on_playlist(shuffled_tracks, existing_shuffle)
    else
      puts 'Creating new shuffled playlist'
      shuffle_playlist = user.create_playlist!(shuffled_playlist_name)
      add_tracks_to_playlist(shuffled_tracks, shuffle_playlist)
    end

    puts pastel.green.bold("Split complete! Created #{track_chunks.length} split playlists and 1 shuffled playlist.")
  end

  def recreate_together_mega_mix
    puts 'Creating Together Mega Mix...'

    # 0. Load recently played tracks to exclude
    puts 'Loading recently played tracks...'
    recently_played_tracks = all_recently_played
    puts "  Loaded #{recently_played_tracks.length} recently played tracks to exclude"

    # 1. Load tracks from Inês-Starred playlist, remove recently played, randomize and take first 100
    puts 'Loading tracks from Inês-Starred playlist...'
    ines_starred = playlist_by_uri('spotify:playlist:32uFzY3WoyrnyMDFExwpyT')
    ines_tracks = load_all_tracks(ines_starred, market: nil)
    ines_tracks = subtract_tracks_by_metadata(ines_tracks, recently_played_tracks)
    ines_sample = ines_tracks.sample(100)
    puts "  Loaded #{ines_sample.length} tracks from Inês-Starred (after removing recents)"

    # 2. Load my saved tracks, remove recently played, randomize and take first 100
    puts 'Loading saved tracks...'
    saved_tracks = load_saved_tracks(market: nil)
    saved_tracks = subtract_tracks_by_metadata(saved_tracks, recently_played_tracks)
    saved_sample = saved_tracks.sample(100)
    puts "  Loaded #{saved_sample.length} saved tracks (after removing recents)"

    # 3. Load Future Setlists playlist, remove recently played, randomize and take first 100
    puts 'Loading tracks from Future Setlists...'
    future_setlists = playlist_by_name('Future Setlists')
    future_tracks = load_all_tracks(future_setlists, market: nil)
    future_tracks = subtract_tracks_by_metadata(future_tracks, recently_played_tracks)
    future_sample = future_tracks.sample(100)
    puts "  Loaded #{future_sample.length} tracks from Future Setlists (after removing recents)"

    # 4. Mix all three by zipping (interleaving)
    puts 'Mixing all tracks...'
    mixed_tracks = ines_sample.zip(saved_sample, future_sample).flatten.compact
    puts "  Total mixed tracks: #{mixed_tracks.length}"

    # 5. Save to Together Mega Mix, replacing existing tracks
    puts 'Saving to Together Mega Mix...'
    together_mega_mix = playlist_by_name('Together Mega Mix')
    raise "Playlist 'Together Mega Mix' not found!" unless together_mega_mix

    replace_all_tracks_on_playlist(mixed_tracks, together_mega_mix)
    puts pastel.green.bold("Together Mega Mix recreated with #{mixed_tracks.length} tracks!")
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
      Script.new.play_playlist_on_zipp('spotify:playlist:7oorBA7hnNJngmox1JNrGW', shuffle: false)
    when 'zipp_home'
      Script.new.play_playlist_on_zipp('spotify:playlist:20IsQZexWUDfjim8Xn3g52')
    when 'zipp_playlist'
      Script.new.play_playlist_on_zipp_named('Together Mega Mix')
    when 'clean'
      Script.new.clean
    when 'dedup'
      script = Script.new(verbose: true)
      script.dedup(script.playlist_by_name(ARGV[1]))
    when 'remove_current_track'
      Script.new.remove_track_from_playing_playlist
    when 'playlist_lyrics'
      Script.new.playlist_lyrics(ARGV[1])
    when 'check_playlist_name_changes'
      Script.new.check_playlist_name_changes(%w[0CHJozYEL8O421waNFDEvE])
    when 'shuffle_run_mad'
      Script.new.shuffle_run_mad
    when 'split_run_mad_master'
      Script.new(verbose: true).split_run_mad_master
    when 'recreate_together_mega_mix'
      Script.new(verbose: true).recreate_together_mega_mix
    when 'playlist_without_recently_played'
      script = Script.new(verbose: true)
      playlist1 = script.get_playlist(ARGV[1])
      playlist2 = script.recently_played_playlist
      script.playlist_without_playlist(playlist1, playlist2)
    when 'remove_recents'
      script = Script.new(verbose: true)
      playlist1 = script.get_playlist(ARGV[1])
      playlist2 = script.recently_played_playlist
      tracks_to_remove = script.load_all_tracks(playlist2)
      script.remove_tracks_by_metadata(tracks_to_remove, playlist1, ARGV[1] == 'current')
      script.playlist_without_playlist(playlist1, playlist2)
    when 'playlist_without_playlist'
      script = Script.new(verbose: true)
      playlist1 = script.get_playlist(ARGV[1])
      playlist2 = script.get_playlist(ARGV[2])
      shuffle = ARGV[3].include?('shuffle')
      script.playlist_without_playlist(playlist1, playlist2, shuffle: shuffle)
    when 'playlist_without_saved'
      script = Script.new(verbose: true)
      playlist1 = script.get_playlist(ARGV[1])
      shuffle = ARGV[2].include?('shuffle')
      script.playlist_without_saved(playlist1, shuffle: shuffle)
    when 'import'
      prompt = TTY::Prompt.new
      artist = prompt.ask("What's the artist name?")
      tracks = prompt.multiline("Enter the tracks for #{artist}").map { |l| l.strip }
      Script.new.import(artist, tracks)
    when 'pry'
      Script.new.pry
    when 'help'
      puts <<~HELP
        Commands:
        - resume_zipp
        - resume_computer
        - zipp_weekly_playlist
        - zipp_home
        - zipp_playlist
        - clean
        - dedup <playlist_name>
        - remove_current_track
        - playlist_lyrics <playlist_id>
        - check_playlist_name_changes
        - shuffle_run_mad
        - split_run_mad_master
        - recreate_together_mega_mix
        - playlist_without_recently_played <playlist_uri>
        - playlist_without_playlist <playlist_uri> <playlist_uri> [shuffle]
        - playlist_without_saved <playlist_uri> [shuffle]
        - import
        - pry
        - help

        Note:
        - playlist_uri can be 'current', 'recents', a playlist URI, or a playlist URL.
      HELP
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
