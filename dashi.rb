require 'rubygems'
require 'xmlsimple'
require 'builder'
require 'csv'
require 'diff/lcs'

class WrongArgumentsException < StandardError; end
$_version = '0.7'
$_convert = 'convert'
$_synchronize = 'synchronize'
$_merge = 'merge'
$_plurals='plurals'
$_string_array='string-array'
$_string='string'
$_lang_map = {
    en: 'english',
    de: 'german',
    pl: 'polish',
    it: 'italian',
    fr: 'french'
}

class FormatConverter
  def self.csv_to_xml_lang(string)
    xml_lang = Hash.new
    key_name = 'name'
    key_content = 'content'
    key_item = 'item'
    rows = Array.new
    CSV.foreach(string, encoding: "UTF-8") {|row| rows+=[row]}
    lang_types = rows[0][1..rows[0].length]
    lang_types.each { |lang| xml_lang[lang] = Hash.new}
    rows[1..rows.length].each do |row|
      name = row[0]
      values = row[1..row.length]
      type = 'string'
      num = nil
	  if name.nil?
		puts 'Nil row detected'
		next
	  end
      if name.index '@'
        type, name, num = name.split '@'
      end
      values.each_index do |lang_index|
        value_lang = values[lang_index]
        xml = xml_lang[lang_types[lang_index]]
        xml[type] = Array.new if xml[type].nil?
        if num.nil?
          xml[type] += [{key_name => name, key_content => value_lang}]
        else
          sub_tag = nil
          xml[type].each do |field|
            if field[key_name] == name
              sub_tag = field
            end
          end
          if sub_tag.nil?
            sub_tag = {key_name => name, key_item => []}
            xml[type] += [sub_tag]
          end
          hash_type = num.index '='
          if hash_type.nil?
            sub_tag[key_item] += [value_lang]
          else
            attr_name, attr_value = num.split '='
            sub_tag[key_item] += [{attr_name => attr_value, key_content => value_lang}]
          end
        end
      end
    end
    xml_lang
  end
  def self.xml_hash_to_xml(xml_hash)
    key_name = 'name'
    key_content = 'content'
    key_item = 'item'
    output = String.new
    x = Builder::XmlMarkup.new(:target => output, :indent => 4)
    x.instruct!
    x.resources('xmlns:tools' => 'http://schemas.android.com/tools') do
      xml_hash.each do |type, value_array|
        value_array.each do |value_hash|
          content = value_hash[key_content]
		  if content.nil?
			item = value_hash[key_item]
			if item.nil?
				x.tag!(type, "", name: value_hash[key_name])
			else
				x.tag!(type, name:value_hash[key_name]) do
				  item.each { |i|
					if i.is_a?(Hash)
					  x.item(i[key_content],i.reject { |k| k == key_content })
					else
					  x.item i
					end
				  }
				end
			end
		  else
		    if content.is_a?(String)
              x.tag!(type, content, name: value_hash[key_name])  
			end
		  end
        end
      end
    end
    output
  end
  def self.csv_to_xml(csv, options)
    xml = csv_to_xml_lang(csv)[options[:lang]]
    xml_hash_to_xml xml
  end

  def self.xml_lang_to_array(xml_lang)
    lang_map = ['name']
    xml_lang.each_key { |k| lang_map+=[k] }
    array_map = Hash.new
    xml_lang.each do |lang, xml_hash|
      xml_hash.each { |tag, value|
        next if value.kind_of?(String)
        value.each { |element|
          next unless element['tools:ignore'].nil?
          name = element['name']
          content = element['content']
          items = element['item']
          if !content.nil? && items.nil?
            array_map[name] = Hash.new if array_map[name].nil?
            array_map[name][lang] = content
          end
          items.each_index { |index|
			item = items[index]
            quantity = item['quantity']
            content = item['content']
            content = item if item.kind_of? String
            key = "#{tag}@#{name}"
            key+= quantity.nil? ? "@##{index}" : "@quantity=#{quantity}"
            unless content.nil?
              array_map[key] = Hash.new if array_map[key].nil?
              array_map[key][lang] = content
            end
          } unless items.nil?
        }
      }
    end
    array = [lang_map]
    array_map.each do |key, lang_value|
      row = [key]
      lang_map[1..lang_map.length].each { |lang|
        val = lang_value[lang]
        row += [val.nil? ? '' : val]
      }
      array+=[row]
    end
    array
  end

  def self.xml_hash_to_array(xml_hash, options)
    lang = options[:lang].nil? ? 'english' : options[:lang]
    lang_map = ['name', lang]
    array = [lang_map]
    xml_hash.each {|tag,value|
      next if value.kind_of?(String)
      value.each {|element|
        next unless element['tools:ignore'].nil?
        name = element['name']
        content = element['content']
        items = element['item']
        array += [[name, content]] unless content.nil?
        items.each_index { |index|
		  item = items[index]
          quantity = item['quantity']
          content = item['content']
          content = item if item.kind_of? String
          key = "#{tag}@#{name}"
          key+= quantity.nil? ? "@##{index}" : "@quantity=#{quantity}"
          array += [[key, content]]
        } unless items.nil?
      }
    }
    array
  end
  def self.xml_to_csv(xml, options)
    xml_hash = XmlSimple.xml_in(xml)
    xml_hash_to_csv(xml_hash,options)
  end
  def self.xml_hash_to_csv(xml_hash, options)
    a = xml_hash_to_array(xml_hash,options)
    array_to_csv a
  end
  def self.array_to_csv(array)
    options = {force_quotes: true}
    csv = ''
    array.each { |line|
      csv << CSV.generate_line(line,options)
    }
    csv
  end

end

class Synchronizer

  def initialize(options = Hash.new)
    @options = options
    @verbose = options['verbose']
  end

  def change_xml_file(file, hashes)
    text= File.read file
    change_count = 0
    hashes.each do |key, value|
      start_pos = text.index('name="'+key+'"')
      if start_pos.nil?
        puts "Key: #{key} not found!" if @verbose
      else
        beginning = text.index('>', start_pos) + 1
        ending = text.index('</string>', beginning) - 1
        old_value = text.slice(beginning..ending)
        if old_value != value
          text.slice! beginning..ending
          text.insert(beginning, value)
          change_count+=1
          puts "Replacing: #{key} = #{old_value} with #{value}" if @verbose
        end
      end
    end
    f = File.open(file, 'w+')
    f << text
    f.close
    puts "Changed #{change_count} / #{hashes.length} lines"
  end

  def change_csv_file(file, hashes)
    text= File.read file
    change_count = 0
    hashes.each do |key, value|
      start_pos = text.index(key)
      if start_pos.nil?
        puts "Key: #{key} not found!" if @verbose
      else
        beginning = text.index('>', start_pos) + 1
        ending = text.index('</string>', beginning) - 1
        old_value = text.slice(beginning..ending)
        if old_value != value
          text.slice! beginning..ending
          text.insert(beginning, value)
          change_count+=1
          puts "Replacing: #{key} = #{old_value} with #{value}" if @verbose
        end
      end
    end
    f = File.open(file, 'w+')
    f << text
    f.close
    puts "Changed #{change_count} / #{hashes.length} lines"
  end
end

class String
  def extension
    split('.').last
  end

  def filename
    split('/').last
  end

  def ends_with?(name)
    /#{name}$/.match self
  end

  def starts_with?(name)
    /^#{name}/.match self
  end
end

def validate_file(filename)
  if filename.is_a? String
    raise WrongArgumentsException, "File #{filename} does not exist" unless File.exist?(filename)
  elsif filename.is_a? Array
    filename.each { |f|
      raise WrongArgumentsException, "File #{f} does not exist" unless File.exist?(f)
    }
  end
end

def interpret(args)
  raise WrongArgumentsException, 'Wrong arguments' if args.nil? || args.empty? || !args.kind_of?(Array)
  cmd = args[0]
  files = args[1..args.length]
  case cmd
    when $_merge
      merge files
    when $_convert
      convert files
    when $_synchronize
      synchronize files
    when 'version'
      puts "#{__FILE__.filename} version: #{$_version}"
    when 'test'
      run_test
    else
      raise WrongArgumentsException, 'Unknown operation'
  end
end

def convert(args)
  input = args[0]
  output = args[1]
  raise WrongArgumentsException, 'Wrong type' unless input.kind_of?(String) && output.kind_of?(String)
  validate_file input
  lang = args[2].nil? ? 'english' : args[2]
  if input.extension == 'xml' && output.extension == 'csv'
    File.open(output, 'w+') {|f| f << FormatConverter::xml_to_csv(input, lang: lang) }
  elsif input.extension == 'csv' && output.extension == 'xml'
    File.open(output, 'w+') { |f| f << FormatConverter::csv_to_xml(input, lang: lang) }
  else
    raise WrongArgumentsException, 'File extensions match not found'
  end
end

def merge(args)
  path = args[0]
  input = args[1]
  output = args[2]
  raise WrongArgumentsException, 'Wrong type' unless input.kind_of?(String) && output.kind_of?(String)
  raise WrongArgumentsException, 'Path not found' unless File.directory?(path)
  xml_lang = Hash.new
  Dir["#{path}/**/**"].select { |f| f.ends_with?(input) }.each do |filepath|
    dir = filepath.split('/')
    dir = dir[dir.length - 2]
    lang_code = dir.index('-').nil? ? 'en' : dir.split('-').last
    xml_lang[$_lang_map[lang_code.to_sym]] = XmlSimple.xml_in filepath
  end
  array = FormatConverter::xml_lang_to_array xml_lang
  File.open(output, 'w+') { |f| f << FormatConverter::array_to_csv(array) }
end

def synchronize(args)
  input = args[0]
  output = args[1]
  raise WrongArgumentsException, 'Wrong type' unless input.kind_of?(String) && output.kind_of?(String)
  validate_file args
  if input.extension == 'xml' && output.extension == 'csv'
    # xml = XmlSimple.new(input)
    # XmlP::convert(input, output)
  elsif input.extension == 'csv' && output.extension == 'xml'

    # CsvP::convert(input, output)
  else
    raise WrongArgumentsException, 'File extensions match not found'
  end
end

def run_test
  interpret %w(convert test/foo.xml test/bar.csv)
  interpret %w(convert test/bar.csv test/bar.xml)
  interpret %w(merge test/res/ foo.xml test/bar2.csv)
end

def show_help
  filename = __FILE__.filename
  puts "#{filename} is an script written to convert Android XML strings to CSV and back"
  puts 'Use cases:'
  puts "\"#{filename} #{$_convert} filename.xml filename.csv\" - convert xml file to csv file"
  puts "\"#{filename} #{$_convert} filename.xml filename.csv language\" - convert xml file to csv file, naming the values column 'language'"
  puts "\"#{filename} #{$_convert} filename.csv filename.xml\" - convert csv file to xml file"
  puts "\"#{filename} #{$_convert} filename.csv filename.xml language\" - convert csv file to xml file, extracting column 'language' to xml"
  puts "\"#{filename} #{$_merge} /path/to/resources values.xml filename.csv\" - look for xml files in path following values-lang scheme using values.xml as file to look for; then convert them to filename.csv"
  # puts "\"#{filename} #{$_synchronize} filename.xml filename.csv\" - copy changed values from xml file to csv file"
  # puts "\"#{filename} #{$_synchronize} filename.csv filename.xml\" - copy changed values from csv file to xml file"
end

if __FILE__ == $PROGRAM_NAME
  begin
    interpret ARGV
  rescue WrongArgumentsException => e
    puts 'Exception: '+ e.to_s
    show_help
  end
end