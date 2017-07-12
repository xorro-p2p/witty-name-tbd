require 'minitest/autorun'
require_relative '../node.rb'
require_relative "../routing_table.rb"
require_relative "../kbucket.rb"
require_relative "../contact.rb"

class RoutingTableTest < Minitest::Test
  def setup
    @node = Node.new('0')
    @routing_table = RoutingTable.new(@node)
  end

  def test_create_routing_table
    assert_equal(@routing_table.node, @node)
    assert_equal(@routing_table.buckets.size, 1)
  end

  def test_insert_node_with_duplicate_id
    new_node = Node.new('0')

    assert_raises(ArgumentError) do
      @routing_table.insert(new_node)
    end
  end

  def test_insert_find_matching_bucket_with_one_bucket
    new_node = Node.new('1')
    result = @routing_table.find_matching_bucket(new_node)
    assert_equal(@routing_table.buckets[0], result)
  end

  def test_insert_find_matching_bucket_with_two_buckets_no_shared_bits
    new_node = Node.new('15')
    @routing_table.create_bucket
    result = @routing_table.find_matching_bucket(new_node)

    assert_equal(@routing_table.buckets[0], result)
  end

  def test_insert_find_matching_bucket_with_two_buckets_one_shared_bit
    new_node = Node.new('7')
    @routing_table.create_bucket
    result = @routing_table.find_matching_bucket(new_node)

    assert_equal(@routing_table.buckets[1], result)
  end

  def test_insert_find_matching_bucket_with_two_buckets_no_exact_shared_bits
    new_node = Node.new('1')
    @routing_table.create_bucket
    result = @routing_table.find_matching_bucket(new_node)

    assert_equal(@routing_table.buckets[1], result)
  end

  def test_insert_find_matching_bucket_with_k_buckets_no_exact_shared_bits
    node2 = Node.new('2')
    node7 = Node.new('7')
    node15 = Node.new('15')

    3.times do 
      @routing_table.create_bucket
    end

    result2 = @routing_table.find_matching_bucket(node2)
    result7 = @routing_table.find_matching_bucket(node7)
    result15 = @routing_table.find_matching_bucket(node15)

    assert_equal(@routing_table.buckets[2], result2)
    assert_equal(@routing_table.buckets[1], result7)
    assert_equal(@routing_table.buckets[0], result15)
  end

  def test_insert_if_bucket_full_and_splittable_diff_xor_distance
    # result is buckets.size = 2
  end

  def test_insert_if_bucket_full_and_splittable_same_xor_distance
    # result is buckets.size = 1
  end

  def test_insert_if_bucket_full_and_splittable_redistribute_contacts
    
  end

  def test_insert_if_bucket_full_and_not_splittable

  end

  def test_insert_if_bucket_full_and_not_splittable_and_node_live

  end

  def test_insert_if_bucket_full_and_not_splittable_and_node_not_live

  end

  def test_insert_if_bucket_not_full

  end

  def test_kbuckets_boundary
    # try to create k + 1 buckets; should still have k buckets
  end
end