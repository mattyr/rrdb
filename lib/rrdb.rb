#!/usr/bin/env ruby -wKU

# = rrdb.rb -- A Round Robin Database Wrapper
#
#  Created by James Edward Gray II on 2008-06-19.
#  Copyright 2008 Gray Productions Software Inc., all rights reserved.
# 
# See RRDB for documentation.

#
# This class wraps an .rrd file on the disk by shelling out to rrdtool to
# perform read and write actions on the database.  The primary features of this
# simple wrapper are:
# 
# * Each instance manages a separate database keyed on unique ID's you provide
# * Database creation is delayed until the first update so fields will be known
# * Extra fields can be reserved in the database and the wrapper will
#   automatically claim them as needed when new fields appear in future updates
# * Field names are safely mapped to names acceptable to rrdtool whenever
#   possible and a method is provided to help you map them back to your
#   preferred names
# * Fetch operations return data in time slots, by field name
# 
# This class is not multiprocessing safe for write operations.
# 
class RRDB
  # The version number for this release of the code.
  VERSION = "0.0.1"
  
  #
  # This method generates Exception subclasses, as needed.  When the code
  # references any constant ending in Error, a subclass of RuntimeError is built
  # and assigned to that name.  See the documentation for each method for a list
  # of the errors it can raise.
  # 
  def self.const_missing(error_name)  # :nodoc:
    if error_name.to_s =~ /Error\z/
      const_set(error_name, Class.new(RuntimeError))
    else
      super
    end
  end
  
  #
  # This helper is used to shell out to external command, like rrdtool.  It runs
  # the command with STDOUT and STDERR merged into a single stream.  If the
  # command exits successfully, the output from this combined stream is
  # returned.  Otherwise, +nil+ is returned and you can call last_error() to
  # retrieve the contents of the stream.
  # 
  def self.run_command(command)
    output = `#{command} 2>&1`
    if $?.success?
      @last_error = nil
      output
    else
      @last_error = output
      nil
    end
  rescue
    nil
  end
  
  # 
  # Returns the contents of the combined STDOUT and STDERR stream after a call
  # to run_command() where the command reported a non-success exit status.  This
  # method will always return +nil+ after a successful call to run_command().
  # 
  def self.last_error
    @last_error
  end
  
  # 
  # :call-seq:
  #   config         => config_hash
  #   config( hash ) => updated_config_hash
  #   config( key  ) => config_value
  # 
  # This method allows you to read and write configuration settings for this
  # class.  Just pass in a Hash of new settings to have them merged into the
  # existing configuration.  Recognized settings are:
  # 
  # <tt>:rrdtool_path</tt>::         The path to the rrdtool executable.  This
  #                                  library will attempt to find it on load,
  #                                  but you may need to help it along under
  #                                  some circumstances.
  # <tt>:database_directory</tt>::   The directory .rrd files will be stored in.
  #                                  This defaults to the working directory.
  # <tt>:reserve_fields</tt>::       The total number of fields the database
  #                                  is expected to have.  A number of fields
  #                                  will be reserved in all databases created
  #                                  equal to this count minus the count of
  #                                  fields in the first update for that
  #                                  database.  These fields will be claimed as
  #                                  needed by future updates.  Defaults to
  #                                  <tt>10</tt>.
  # <tt>:data_sources</tt>::         If set to a String, this value will be used
  #                                  as the Data Source Type for all fields
  #                                  created.  Alternately, you may set this to
  #                                  any object with a <tt>[]</tt> method that
  #                                  looks up the field and returns a DST String
  #                                  (Hash and Proc are good examples).  This
  #                                  defaults to <tt>"GAUGE:600:U:U"</tt>.
  # <tt>:round_robin_archives</tt>:: An Array of RRA statements added to all
  #                                  databases generated by this library.  (You
  #                                  don't need to include the "RRA:" prefix.)
  #                                  This field defaults to an empty Array and 
  #                                  thus must be set or overriden by your code.
  # <tt>:database_step</tt>::        The optional step parameter passed to all
  #                                  databases created.
  # <tt>:database_start</tt>::       If set, this will override the start time
  #                                  for all databases created.
  # 
  def self.config(hash_or_key = nil)
    case hash_or_key
    when nil
      @config ||= Hash.new
    when Hash
      config.merge!(hash_or_key)
    else
      config[hash_or_key]
    end
  end
  
  # Default configuration.
  config :rrdtool_path         => ( run_command("which rrdtool") ||
                                    "rrdtool" ).strip,
         :database_directory   => ".",
         :reserve_fields       => 10,
         :data_sources         => "GAUGE:600:U:U",
         :round_robin_archives => Array.new
  
  #
  # Given a field name used in a call to update(), this method will return the
  # name used inside the .rrd file.  This is helpful for mapping field back to
  # the values your application prefers.
  # 
  def self.field_name(name)
    name.to_s.tr( "-~!@\#$%^&*+=|<>./?",
                  "mtbahdpcnmveplgddq" ).delete("^a-zA-Z0-9_")[0..18]
  end
  
  #
  # This constructor build a new instance to wrap a round robin database with
  # the provided unique +id+.  This +id+ will be part of the file name used to
  # store this database.  If a database with the +id+ already exists, it will
  # be used for all interactions with the object.  Otherwise, a new database
  # will be created on the first call to update().
  # 
  def initialize(id)
    @id = id
  end
  
  # The unique +id+ for this database instance.
  attr_reader :id
  
  # 
  # The path to the disk file representation of this database.  Be warned that
  # this may not exist yet for a new +id+ where update() has not yet been
  # called.
  # 
  def path
    File.join(self.class.config[:database_directory], "#{id}.rrd")
  end
  
  #
  # Returns an Array of field names used in the database, if +include_types+ is
  # +false+.  When +true+, a Hash is returned mapping field names to their DST.
  # An empty Array or Hash is returned for uncreated databases.
  # 
  def fields(include_types = false)
    schema = rrdtool(:info).to_s
    fields = schema.scan(/^ds\[([^\]]+)\]/).flatten.uniq
    if include_types
      Hash[ *fields.map { |f|
        [ f, "#{schema[/^ds\[#{f}\]\.type\s*=\s*"([^"]+)"/, 1]}:"            +
             "#{schema[/^ds\[#{f}\]\.minimal_heartbeat\s*=\s*(\d+)/, 1]}:"   + 
             "#{schema[/^ds\[#{f}\]\.min\s*=\s*(\S+)/, 1].sub('NaN', 'U')}:" +
             "#{schema[/^ds\[#{f}\]\.max\s*=\s*(\S+)/, 1].sub('NaN', 'U')}" ]
      }.flatten ]
    else
      fields
    end
  rescue InfoError
    include_types ? Hash.new : Array.new
  end
  
  #
  # Returns the step used in this database, or the default 300 for an uncreated
  # database.
  # 
  def step
    (rrdtool(:info).to_s[/^step\s+=\s+(\d+)/, 1] || 300).to_i
  rescue InfoError
    300
  end
  
  #
  # This method is the interface for adding data to the database.  You pass a
  # +time+ the data should be recorded under and a +data+ Hash of fields you
  # wish to store in the database.
  # 
  # The first time this method is called for a new database, the database will
  # be generated to contain the needed fields (plus any extras reserved by the
  # configuration).  Future calls will claim reserved fields if needed, to
  # support new field names.  Either way, both types of calls end with the data
  # being pushed into the database.
  # 
  # This method can raise the following errors:
  # 
  # <tt>FieldNameConflictError</tt>:: This error signals that your field names
  #                                   cannot be cleanly converted into names
  #                                   RRDtool will accept.  It's possible that
  #                                   cleaning them resulted in an unacceptable
  #                                   size or that cleaning them led to
  #                                   duplicate names.
  # <tt>FieldsExhaustedError</tt>::   An attempt to claim new fields was made,
  #                                   but there are not enough reserved fields
  #                                   in the database to satisfy the request.
  # <tt>CreateError</tt>::            A database could not be created, likely
  #                                   due to a malformed schema taken from the
  #                                   configuration settings.
  # <tt>TuneError</tt>::              A database could not be modified, again
  #                                   probably because of a malformed schema.
  # <tt>UpdateError</tt>::            The attempt to add data to the database
  #                                   failed for whatever reason (a time before
  #                                   the previous update, for example).
  # 
  def update(time, data)
    safe_data = Hash[*data.map { |f, v| [self.class.field_name(f), v] }.flatten]
    if safe_data.size != data.size or
       safe_data.keys.any? { |f| not f.size.between?(1, 19) }
      raise FieldNameConflictError,
            "Your field names cannot be unambiguously converted to RRDtool " +
            "field names (1 to 19 [a-zA-Z0-9_] characters)."
    end
    if File.exist? path
      claim_new_fields(safe_data.keys)
    else
      create_database(time, safe_data.keys)
    end
    params = fields.map do |f|
      safe_data[f].send(safe_data[f].to_s =~ /\A\d+\./ ? :to_f : :to_i)
    end
    rrdtool(:update, "'#{time.to_i}:#{params.join(':')}'")
  end
  
  #
  # This method is the primary interface for reading data out of the database.
  # Pass into +field+ the name of the consolidation function you wish to pull
  # data from.  You may also pass standard RRDtool fetch options in the +range+
  # Hash (<tt>:start</tt>, <tt>:end</tt>, and <tt>:resolution</tt>).  The return
  # value is a Hash, keyed by times, where the value for each time is a nested
  # Hash of fields and their values at that time.
  # 
  # This method can raise a FetchError if data cannot be read for any reason.
  # 
  def fetch(field, range = Hash.new)
    params = "'#{field}' "
    %w[start end resolution].each do |option|
      if param = range[option.to_sym] || range[option]
        params << " --#{option} '#{param.to_i}'"
      end
    end
    data    = rrdtool(:fetch, params)
    fields  = data.to_a.first.split
    results = Hash.new
    data.scan(/^\s*(\d+):((?:\s+\S+){#{fields.size}})/) do |time, values|
      floats = values.split.map { |f| f =~ /\A\d/ ? Float(f) : 0 }
      results[Time.at(time.to_i)] = Hash[*fields.zip(floats).flatten]
    end
    results
  end
  
  private
  
  # 
  # This method is called by update() to create a non-existent database.  It
  # requires the starting +time+ for the database as well as the +field_names+
  # that should be added to the database.  It will use the current configuration
  # to build DST's, add RRA's, reserve fields, and set a step for the database.
  # 
  # This method can raise a CreateError if the database cannot be created due to
  # an illegal schema.
  # 
  def create_database(time, field_names)
    schema = String.new
    %w[step start].each do |option|
      if setting = self.class.config[:"database_#{option}"]
        schema << " --#{option} '#{setting.to_i}'"
      elsif option == "start"
        schema << " --start '#{(time - 10).to_i}'"
      end
    end
    field_names.each { |f| schema << " 'DS:#{f}:#{field_type(f)}'" }
    (self.class.config[:reserve_fields].to_i - field_names.size).times do |i|
      name   =  "_reserved#{i}"
      schema << " 'DS:#{name}:#{field_type(name)}'"
    end
    Array(self.class.config[:round_robin_archives]).each do |a|
      schema << " 'RRA:#{a}'"
    end
    rrdtool(:create, schema.strip)
  end
  
  # 
  # This method is called by update() before each attempt to add data to an
  # existing database.  The +field_names+ for this update will be compared with
  # the existing fields for the database, and reserved fields are claimed to
  # make up any differences.  The current configuration will be used to generate
  # DST's.
  # 
  # This method can raise a FieldsExhaustedError if this update() would require
  # more fields than are currently reserved or a TuneError if the database
  # schema for the new fields is invalid.
  # 
  def claim_new_fields(field_names)
    old_fields = fields
    new_fields = field_names - old_fields
    unless new_fields.empty?
      reserved = old_fields.grep(/\A_reserved\d+\Z/).
                            sort_by { |f| f[/\d+/].to_i }
      if new_fields.size > reserved.size
        raise FieldsExhaustedError,
              "There are not enough reserved fields to complete this update."
      else
        claims = new_fields.zip(reserved).
                            map { |n, o| " -r '#{o}:#{n}'" +
                                         " -d '#{n}:#{field_type(n)}'" }.
                            join.strip
        rrdtool(:tune, claims)
      end
    end
  end
  
  # 
  # This helper returns a DST for the passed +field_name+ based on the current
  # configuration.  If no type is provided by the configuration,
  # <tt>GAUGE:600:U:U</tt> will be given as a default.
  # 
  def field_type(field_name)
    if (setting = self.class.config[:data_sources]).is_a? String
      setting
    else
      setting[field_name.to_sym] || setting[field_name] || "GAUGE:600:U:U"
    end
  end
  
  #
  # This helper shells out to the rrdtool program.  The first argument is the
  # +command+ to invoke and +params+ is an optional String of command-line
  # arguments to pass to on.
  # 
  # This command generates errors based on the +command+ run.  For example, if
  # called with the <tt>:create</tt> command, failures will be raised as
  # CreateError objects.
  # 
  def rrdtool(command, params = nil)
    self.class.run_command(
      "#{self.class.config[:rrdtool_path]} #{command} '#{path}' #{params}"
    ) or raise self.class.const_get("#{command.to_s.capitalize}Error"),
               self.class.last_error
  end
end
