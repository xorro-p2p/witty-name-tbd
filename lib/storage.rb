require 'yaml'

module Storage
  def self.file_exists?(file_name='id.yml')
    # add some validation, valid yaml file, contains key properties
    File.exists?(File.join(ENV['home'], file_name))
  end

  def self.valid_file?(file_name='id.yml')
    file = YAML.load_file(File.join(ENV['home'], file_name))
    file && file.id && file.id.to_i.between?(0, 2 ** ENV['bit_length'].to_i)
  end

  def self.is_valid_id_file(id_file)
    f = YAML::load_file(id_file)
    f && f[:id] && f[:id].to_i.between?(0,2 ** ENV['bit_length'].to_i)
  end

  def self.load_file(file_name='id.yml')
    YAML.load_file(File.open(File.join(ENV['home'], file_name)))
  end

  def self.write_to_disk(node, file_name='id.yml')
    return if ENV['development'] == "true"

    File.open(File.join(ENV['home'], file_name), 'w') { |f| f.write(node.to_yaml) }
  end
end
