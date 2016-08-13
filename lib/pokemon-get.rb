require 'net/http'
require 'json'
require 'optparse'
require 'logger'

class Pokemon
  attr_reader :data
  def initialize(data)
    @data = data
    @data[:disappear_time] = {:epoch => data[:disappear_time], :human => Time.at(data[:disappear_time]/1000)}
    @data[:current_time] = Time.now
  end
end

class PokeClient
  @@encounters = []

  def initialize(target)
    @uri = URI.parse target
    @http = Net::HTTP.new @uri.host, @uri.port
    @request = Net::HTTP::Get.new('/map-data')
  end

  def get_encounters(file)
    File.readlines(file).each do |event|
      @@encounters << JSON.parse(event)['encounter_id']
    end
  end

  def reset_encounters
    @@encounters = []
  end

  def get_pokemon
    @pokemons = []
    data = @http.request @request
    JSON.parse(data.body, {:symbolize_names => true})[:pokemons].each do |pokespawn|
      if @@encounters.include? pokespawn[:encounter_id]
        next
      else
        @@encounters << pokespawn[:encounter_id]
        @pokemons << Pokemon.new(pokespawn)
      end
    end
    return @pokemons
  end
end

class PokeDex
  attr_reader :newfile, :oldfile

  def initialize(library, delay)
    @library = library
    @delay = delay
    open_file
  end

  def write(pokemons)
    open_file

    pokemons.each do |pokemon|
      @pokelog.puts pokemon::data.to_json
    end

    @pokelog.close
  end

  private
  def open_file
    time_now = Time.now
    time_yest = Time.at(time_now.to_i - 86400)

    @oldfile = File.join(@library, "pokemon_#{time_yest.day}-#{time_yest.month}.json")
    @newfile = File.join(@library, "pokemon_#{time_now.day}-#{time_now.month}.json")

    io = IO.sysopen(@newfile, 'a')
    @pokelog = IO.new(io, 'a')
  end
end

class PokemonGET
  attr_reader :opts, :client, :pokedex

  def initialize
    @opts = {
      :server  => '127.0.0.1',
      :port    => 5000,
      :pokedex => '/var/log/pokemon',
      :delay   => 60,
      :loglevel => 'warn'
    }

    ARGV << '-h' if ARGV.empty?
    ARGV.options do |opt|
      opt.on('-c', '--config=FILE', 'Configuration file for service', String) do |file|
        @opts.merge! JSON.parse( File.read(file), {:symbolize_names => true} )
      end

      opt.on('-s', '--server=SERVER', 'Hostname or IP', String) do |server|
        server.include?('http://') ? @opts[:server] = server : @opts[:server] = 'http://' + server
      end
      opt.on('-p', '--port=PORT', 'Web server port') { |port| opts[:port] = port }
      opt.on('-l', '--pokedex-library=/DIR/PATH', 'Path to pokelog directory', String) { |library| @opts[:pokedex] = library }
      opt.on('-d', '--delay=SECONDS', 'Number of seconds between checks', Integer) { |delay| @opts[:delay] = delay }
      opt.on('-f', '--logfile=/PATH/TO/LOGFILE', 'Path to service logfile', String) { |logfile| @opts[:logfile] = logfile }
      opt.on_tail('-h', '--help', 'Show this message') do
        puts opt
        exit 30
      end
      opt.parse!
    end

    $LOG = Logger.new(@opts[:logfile]) if @opts[:logfile]
    @client = PokeClient.new [ @opts[:server], @opts[:port] ].join(':')
    @pokedex = PokeDex.new @opts[:pokedex], @opts[:delay]
    @client.get_encounters(@pokedex.oldfile) if File.exists? @pokedex.oldfile
    @client.get_encounters(@pokedex.newfile) if File.exists? @pokedex.newfile
  end

  def self.run!
    pokemon_get = new
    get_exceptions = 0
    get_tries      = 0
    write_exceptions = 0
    write_tries      = 0
    max_exceptions = 5
    tries = 0

    while 1
      begin
        get_tries += 1
        new_pokemon = pokemon_get::client.get_pokemon
      rescue Exception => error_getting
        $LOG.error error_getting
        get_tries = 0
        get_exceptions += 1
      end

      begin
        write_tries += 1
        pokemon_get::pokedex.write new_pokemon if new_pokemon.any?
      rescue Exception => error_writing
        $LOG.error error_writing
        write_tries = 0
        write_exceptions += 1
      end

      if pokemon_get::opts[:loglevel].downcase == 'info'
        new_pokemon.each do |pokemon|
          $LOG.info "new encounter: " + pokemon::data[:encounter_id]
        end
      end

      if get_tries >= 5 || write_tries >= 5
        get_exceptions = 0
        write_exceptions = 0
        get_tries = 0
        write_tries = 0
      end

      if get_exceptions > max_exceptions
        exit 40
      elsif write_exceptions > max_exceptions
        exit 50
      end

      sleep pokemon_get::opts[:delay]
    end
  end
end

# start app
PokemonGET.run!
