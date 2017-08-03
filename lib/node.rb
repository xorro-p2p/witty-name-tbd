require 'open-uri'
require 'digest/sha1'
require 'socket'
require 'ngrok/tunnel'
require_relative '../development.rb'
require_relative 'binary.rb'
require_relative 'routing_table.rb'
require_relative 'contact.rb'
require_relative 'network_adapter.rb'
require_relative 'storage.rb'
require 'json'
require 'pry'


class Node
  attr_accessor :ip, :id, :port, :files, :routing_table, :dht_segment, :is_super, :superport
  def initialize(num_string, network, port='80', is_super=false)
    @port = port
    set_ip
    @network = network
    join(@network)
    @id = num_string
    @routing_table = RoutingTable.new(self)
    generate_file_cache
    @dht_segment = {}
    @is_super = false
    @superport = nil
  end

  def set_super
    @is_super = ENV['SUPER'] == 'true'
  end

  def activate
    set_ip
    @superport = ENV['SUPERPORT']
    return if is_super
    @super_ip = ENV['SUPERIP'] || @ip
    result = JSON.parse(@network.get_info(@super_ip, @superport))
    contact = Contact.new(id: result['id'], ip: result['ip'], port: result['port'])
    ping(contact)
    iterative_find_node(@id)
    broadcast
  end

  def join(network)
    network.nodes.push(self)
  end

  def broadcast
    @files.keys.each do |k|
      address = file_url(@files[k])
      iterative_store(k, address)
    end
  end

  def set_ip
    @ip = lookup_ip
  end

  def lookup_ip
    if ENV['AWS'] == 'true'
      'supernode1.xorro-p2p.com'
    elsif ENV['WAN'] != 'true'
      private_ip = Socket.ip_address_list.detect do |i|
        i.ipv4_private?
      end
      private_ip ? private_ip.ip_address : 'localhost'
    else
      File.basename(NGROK)
    end
  end

  def generate_file_cache
    cache = {}

    Dir.glob(File.expand_path(ENV['uploads'] + '/*')).select { |f| File.file?(f) }.each do |file|
      file_hash = generate_file_id(File.read(file))
      cache[file_hash] = '/files/' + File.basename(file)
    end

    Dir.glob(File.expand_path(ENV['shards'] + '/*')).select { |f| File.file?(f) }.each do |file|
      file_hash = File.basename(file)
      cache[file_hash] = '/shards/' + File.basename(file)
    end

    Dir.glob(File.expand_path(ENV['manifests'] + '/*')).select { |f| File.file?(f) }.each do |file|
      file_hash = File.basename(file, ".xro")
      cache[file_hash] = '/manifests/' + File.basename(file)
    end

    @files = cache
  end

  def add_to_cache(key, value)
    @files[key] = value
    sync
  end

  def add_file(data, name)
    file_hash = generate_file_id(data)
    add_to_cache(file_hash, name)
    iterative_store(file_hash, file_url(name))
  end

  def file_url(filepath)
    "http://#{@ip}:#{@port}#{filepath}"
  end

  def generate_file_id(file_content)
    Binary.sha(file_content).hex.to_s
  end

  def shard_file(file)
    size = File.stat(file).size
    manifest = create_manifest(File.basename(file), size)

    File.open(file, "r") do |fh_in|
      until fh_in.eof?
        piece = fh_in.read(262144) #1048576
        piece_hash = generate_file_id(piece)

        manifest[:pieces].push(piece_hash)
        add_shard(piece_hash, piece) unless @files[piece_hash]
      end
    end

    add_manifest(manifest)
  end

  def add_shard(name, data)
    file_path = '/shards/' + name

    write_to_subfolder(ENV['shards'], name, data)
    add_to_cache(name, file_path)
    iterative_store(name, file_url(file_path))
  end

  def create_manifest(file_name, file_size)
    return {
      :file_name => file_name,
      :length => file_size,
      :pieces => []
    }
  end

  def add_manifest(obj, file_id=nil)
    if file_id.nil?
      file_id = generate_file_id(obj.to_s)
      obj = obj.to_json
    end

    file_name = file_id + '.xro'
    file_path = '/manifests/' + file_name

    write_to_subfolder(ENV['manifests'], file_name, obj)
    add_to_cache(file_id, file_path)
    iterative_store(file_id, file_url(file_path))
  end

  def write_to_subfolder(destination, name, content)
    file_name = destination + '/' + name
    File.open(file_name, 'wb') do |f|
      f.write(content)
    end
  end

  def get(url)
    file = @network.get(url)

    if file
      if File.extname(url) == '.xro'
        add_manifest(file.body, File.basename(url, File.extname(url)))
        reassemble_shards(File.basename(url))
      else
        add_shard(File.basename(url), file.body)
      end
    end
  end

  def reassemble_shards(file)
    file_name = ENV['manifests'] + '/' + file

    manifest = JSON.load(File.read(file_name))
    shards = manifest['pieces']
    shard_count = shards.length

    shards.each do |shard|
      next if @files[shard]
      result = iterative_find_value(shard)
      get(result) if result

      shard_content = File.read(ENV['shards'] + '/' + File.basename(result))
      if generate_file_id(shard_content) == shard
        shard_count -= 1
      end
    end

    if shard_count == 0
      shard_paths = shards.map do |shard|
        ENV['shards'] + '/' + shard
      end

      shard_paths.each do |path|
        File.open(ENV['uploads'] + '/' + manifest['file_name'], 'a') do |f|
          f.write(File.read(path))
        end
      end
    end
  end
  
  def to_contact
    Contact.new({:id => id, :ip => ip, :port => port })
  end

  def receive_ping(contact)
    @routing_table.insert(contact)
  end

  def ping(contact)
    response = @network.ping(contact, to_contact)
    @routing_table.insert(contact) if response
    response
  end

  def store(file_id, address, recipient_contact)
    response = @network.store(file_id, address, recipient_contact, self.to_contact)
    @routing_table.insert(recipient_contact) if response && response.code == 200
  end

  def receive_store(file_id, address, sender_contact)
    if @dht_segment[file_id]
      @dht_segment[file_id].push(address) unless @dht_segment[file_id].include?(address)
    else
      @dht_segment[file_id] = [address]
    end

    @routing_table.insert(sender_contact)
  end

  def iterative_store(file_id, address)
    results = iterative_find_node(file_id)

    results.each do |contact|
      store(file_id, address, contact)
    end
  end

  def receive_find_node(query_id, sender_contact)
    # i received an ID
    # i want my routing table to return an array of k contacts
    # i give the requester the array
    # have to exclude the requestor contact

    closest_contacts = @routing_table.find_closest_contacts(query_id, sender_contact)
    # ping(sender_contact)
    @routing_table.insert(sender_contact)
    closest_contacts
  end

  def find_node(query_id, recipient_contact)
    # i'm telling another node to receive_find_nodes
    # i get an array of k contacts
    # The name of this RPC is misleading. Even if the key to the RPC is the nodeID of an
    # existing contact or indeed if it is the nodeID of the recipient itself, the recipient
    # is still required to return k triples. A more descriptive name would be FIND_CLOSE_NODES. 

    # The recipient of a FIND_NODE should never return a triple containing the nodeID of the requestor.
    # If the requestor does receive such a triple, it should discard it.
    # A node must never put its own nodeID into a bucket as a contact.

    results = @network.find_node(query_id, recipient_contact, self.to_contact)
    results.each do |r|
      @routing_table.insert(r)
    end
    results
  end

  #### refactor this method to accept indeterminate list of array arguments, move to utility module
  def contact_is_not_in_results_or_shortlist(contact, array1, array2)
    !array1.find { |obj| obj.id == contact.id } && !array2.find { |obj| obj.id == contact.id }
  end

  def iterative_find_node(query_id)
    shortlist = []
    results_returned = @routing_table.find_closest_contacts(query_id, nil, ENV['alpha'].to_i)

    until shortlist.select(&:active).size == ENV['k'].to_i
      shortlist.push(results_returned.pop.clone) until results_returned.empty? || shortlist.size == ENV['k'].to_i
      closest_contact = Binary.select_closest_xor(query_id, shortlist)

      # once we get past happy path, we only iterate over items not yet probed
      shortlist.each do |contact|
        temp_results = find_node(query_id, contact)
        temp_results.each do |t|
          results_returned.push(t) if contact_is_not_in_results_or_shortlist(t, results_returned, shortlist)
        end
        #happy path only.. contact will be marked as probed when queried, then marked as active if we receive a reply
        #contact stays in probed mode until reply is received.
        contact.active = true
      end

      break if results_returned.empty? || closest_contact.nil? ||
               Binary.xor_distance_map(query_id, results_returned).min >= Binary.xor_distance(closest_contact.id, query_id)
    end
    return shortlist
  end

  def receive_find_value(file_id, sender_contact)
    result = {}

    if dht_segment[file_id] && !dht_segment[file_id].empty?
      result['data'] = select_address(file_id)
    else
      result['contacts'] = receive_find_node(file_id, sender_contact)
    end
    @routing_table.insert(sender_contact)
    # ping(sender_contact)
    result
  end

  def select_address(file_id)
    values = dht_segment[file_id].clone
    
    values.each do |address|
      response = @network.check_resource_status(address)
      if response == 200
        return address
      else
        evict_address(file_id)
      end
    end

    return nil
  end

  def evict_address(file_id)
    dht_segment[file_id].shift
  end

  def find_value(file_id, recipient_contact)
    results = @network.find_value(file_id, recipient_contact, self.to_contact)

    if results['contacts']
      results['contacts'].each do |r|
        @routing_table.insert(r)
      end
    end
    
    results
  end

  def iterative_find_value(query_id)
    # return dht_segment[query_id] if dht_segment[query_id]

    shortlist = []
    results_returned = @routing_table.find_closest_contacts(query_id, nil, ENV['alpha'].to_i)

    until shortlist.select(&:active).size == ENV['k'].to_i
      shortlist.push(results_returned.pop.clone) until results_returned.empty? || shortlist.size == ENV['k'].to_i
      # closest_contact = Binary.select_closest_xor(query_id, shortlist)
      Binary.sort_by_xor!(id, shortlist)
      closest_contact = shortlist[0]

      # once we get past happy path, we only iterate over items not yet probed
      shortlist.each do |contact|
        temp_results = find_value(query_id, contact)

        if temp_results['data']
          # When this function succeeds (finds the value), a STORE RPC is sent to
          # the closest Contact which did not return the value.
          second_closest = shortlist.find { |c| c.id != contact.id }
          store(query_id, temp_results['data'], second_closest) if second_closest
 
          return temp_results['data']
        end

        if temp_results['contacts']
          temp_results['contacts'].each do |t|
            results_returned.push(t) if contact_is_not_in_results_or_shortlist(t, results_returned, shortlist)
          end
        end
        #happy path only.. contact will be marked as probed when queried, then marked as active if we receive a reply
        #contact stays in probed mode until reply is received.
        contact.active = true
      end

      break if results_returned.empty? || 
               Binary.xor_distance_map(query_id, results_returned).min >= Binary.xor_distance(closest_contact.id, query_id)
    end

    return shortlist
  end

  def sync
    Storage.write_to_disk(self)
  end
end