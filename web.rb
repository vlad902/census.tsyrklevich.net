require 'sinatra'
require 'cgi'
require 'json'
require 'sequel'
require 'logger'
require 'zlib'
require 'base64'
require 'digest'

configure :production do
  require 'newrelic_rpm'
  $production = true
end

DB = Sequel.connect(ENV['MYSQL_DB_URL'] || 'mysql://root@localhost/android_census',
                    :max_connections => 15)
                    #:logger => Logger.new('db.log'))

DB.extension(:error_sql)
DB.extension(:connection_validator)
DB.pool.connection_validation_timeout = 30
#Sequel::MySQL.default_collate = 'utf8_bin'

require_relative 'data_models'

def assert(&block)
  raise "Assertion error" unless yield
end

# http://stackoverflow.com/questions/1765368/how-to-count-duplicates-in-ruby-arrays
def dup_hash(ary)
  ary.inject(Hash.new(0)) { |h,e| h[e] += 1; h }.select { 
    |k,v| v > 1 }.inject({}) { |r, e| r[e.first] = e.last; r }
end

error 400..510 do
  'Error!'
end

# In production we limit calls to results posting/reading/processing endpoints.
def check_production_password(request)
  if $production &&
     (!request.env['HTTP_AUTHORIZATION'] || 
      request.env['HTTP_AUTHORIZATION'] != ENV['ACCESS_CONTROL_PASSWORD'])

    status 403
    raise "Incorrect password"
  end
end

get '/' do
  erb :index
end

get '/devices' do
  erb :devices, :locals => { :devices => Device.all }
end

get '/devices/:id' do |id|
  return 404 if !Device[id]
  erb :device, :locals => { :device => Device[id] }
end

get '/devices/:id/system_properties' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].system_properties,
    :header => "System Properties",
    :model => SystemProperty
  }
end

get '/devices/:id/sysctls' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].sysctls,
    :header => "Sysctls",
    :model => Sysctl
  }
end

get '/devices/:id/environment_variables' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].environment_variables,
    :header => "Environment Variables",
    :model => EnvironmentVariable
  }
end

get '/devices/:id/features' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].features,
    :header => "Features",
    :model => Feature
  }
end

get '/devices/:id/shared_libraries' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].shared_libraries,
    :header => "Shared Libraries",
    :model => SharedLibrary
  }
end

get '/devices/:id/permissions' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].permissions,
    :header => "Permissions",
    :model => Permission
  }
end

get '/devices/:id/providers' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].content_providers,
    :header => "Content Providers",
    :model => ContentProvider
  }
end

get '/devices/:id/small_files' do |id|
  return 404 if !Device[id]
  erb :device_small_files, :locals => {
    :id => id,
    :paths => SmallFile.where(:device_id => id).select_map(:path)
  }
end

get '/devices/:id/small_files/*' do |id, path|
  return 404 if !Device[id]
  file = SmallFile.where(:device_id => id, :path => '/' + path).all.first

  return 404 if !file
  content_type 'text/plain'
  file[:contents]
end

get '/devices/:id/file_permissions' do |id|
  return 404 if !Device[id]
  erb :device_generic_view, :locals => {
    :data => Device[id].file_permissions,
    :header => "File Permissions",
    :model => FilePermission
  }
end

get '/sysctls/:property' do |property|
  erb :by_device_generic_view, :locals => {
    :model => Sysctl,
    :index => property
  }
end

get '/system_properties/:property' do |property|
  erb :by_device_generic_view, :locals => {
    :model => SystemProperty,
    :index => property
  }
end

get '/environment_variables/:variable' do |variable|
  erb :by_device_generic_view, :locals => {
    :model => EnvironmentVariable,
    :index => variable
  }
end

get '/file_permissions/*' do |file|
  erb :by_device_generic_view, :locals => {
    :model => FilePermission,
    :index => '/' + file
  }
end

get '/permissions/:provider' do |permission|
  erb :by_device_generic_view, :locals => {
    :model => Permission,
    :index => permission
  }
end

get '/content_providers/:provider' do |provider|
  erb :by_device_generic_view, :locals => {
    :model => ContentProvider,
    :index => provider
  }
end

get '/features/:feature' do |feature|
  erb :feature, :locals => {
    :feature => feature,
    :devices => Feature.where(:name => feature).all[0].devices
  }
end

get '/shared_libraries/:feature' do |feature|
  erb :feature, :locals => {
    :feature => feature,
    :devices => SharedLibrary.where(:name => feature).all[0].devices
  }
end

get '/piechart/versions.json' do
  versions = DB[:system_properties].where(:property => 'ro.build.version.release').select_map(:value)

  data = dup_hash(versions).map do |version, count|
    {
      'label' => version,
      'value' => count
    }
  end

  JSON.generate(data)
end

get '/piechart/manufacturers.json' do
  manufacturers = DB[:system_properties].where(:property => 'ro.product.manufacturer').select_map(:value)
  manufacturers.map!(&:upcase)

  data = dup_hash(manufacturers).map do |version, count|
    {
      'label' => version,
      'value' => count
    }
  end

  JSON.generate(data)
end

post '/results/new' do
  check_production_password(request)
  Result.create(:data => request.body.read, :processed => false)
  ''
end

get '/results/:id' do |id|
  check_production_password(request)
  Zlib::Inflate.inflate(Result[id][:data])
end

def process_result(result)
  json = JSON.parse(Zlib::Inflate.inflate(result[:data]))

  DB.transaction do
    # Fix jacked up naming inconsistencies
    device_name = json["device_name"]
    device_name.gsub!(/^asus/i, 'ASUS')
    device_name.gsub!(/^acer/i, 'Acer')
    device_name.gsub!(/^lge/i, 'LG')
    device_name.gsub!(/^huawei/i, 'Huawei')
    device_name.gsub!(/^samsung/i, 'Samsung')
    device_name.gsub!(/^motorola/i, 'Motorola')
    device_name.gsub!(/^oppo/i, 'OPPO')
    device_name.gsub!(/^sharp/i, 'Sharp')
    device_name.gsub!(/^toshiba/i, 'Toshiba')
    device_name.gsub!(/^fujitsu/i, 'Fujitsu')
    device_name.gsub!(/^lenovo/i, 'Lenovo')
    device_name.gsub!(/^kyocera/i, 'Kyocera')
    device_name.gsub!(/^fuhu/i, 'Fuhu')
    device_name.gsub!(/^meizu/i, 'Meizu')

    device_name.gsub!(/^tct( alcatel)?/i, 'Alcatel')
    device_name.gsub!(/^coolpad/i, 'YuLong Coolpad')
    device_name.gsub!(/^nubia nx40x/i, 'ZTE Nubia NX40X')

    device_name.gsub!(/^unknown 8150/i, 'YuLong Coolpad 8150')
    device_name.gsub!(/^unknown lenovo/i, 'Lenovo')
    device_name.gsub!('_one_touch_', ' ONE TOUCH ')

    if json['system_properties'] && json['system_properties']['ro.build.description']
      build_description = json['system_properties']['ro.build.description']
    else
      build_description = device_name
    end

    # Don't create a new device entry if we don't need to, re-use the same one but delete old
    #  entries in other tables
    dsearch = Device.where(:name => device_name, :build_description => build_description)
    if dsearch.count == 0
      device = Device.create(:name => device_name, :build_description => build_description)
    else
      device = dsearch.all[0]

      [ :system_properties, :sysctls, :devices_features, :devices_shared_libraries,
        :permissions, :small_files, :file_permissions, :content_providers,
        :environment_variables ].each { |table_name|

        DB[table_name].where(:device_id => device[:id]).delete
      }
    end

    if json["system_properties"]
      DB[:system_properties].multi_insert(
        json["system_properties"].map do |k,v|
          { :property => k, :value => v, :device_id => device[:id] } 
        end
      )
    end

    if json["sysctl"]
      DB[:sysctls].multi_insert(
        json["sysctl"].map do |k,v|
          { :property => k, :value => v, :device_id => device[:id] } 
        end
      )
    end

    if json["features"]
      all_features = json["features"]

      new_features = all_features - DB[:features].distinct(:name).select_map(:name)
      DB[:features].multi_insert(new_features.map { |f| {:name => f} })

      feature_ids = DB[:features].where('name in ?', json["features"]).map { |f| f[:id] }
      DB[:devices_features].multi_insert(
        feature_ids.map do |id|
          { :device_id => device[:id], :feature_id => id }
        end
      )

      assert { json["features"].length == device.features.length }
    end

    if json["system_shared_libraries"]
      new_libraries = json["system_shared_libraries"] - DB[:shared_libraries].distinct(:name).select_map(:name)
      DB[:shared_libraries].multi_insert(new_libraries.map { |l| {:name => l} })

      library_ids = DB[:shared_libraries].where('name in ?', json["system_shared_libraries"]).map { |l| l[:id] }
      DB[:devices_shared_libraries].multi_insert(
        library_ids.map do |id|
          { :device_id => device[:id], :shared_library_id => id }
        end
      )

      assert { json["system_shared_libraries"].length == device.shared_libraries.length }
    end

    if json["permissions"]
      DB[:permissions].multi_insert(
        json["permissions"].map do |data|
          {
            :name => data["name"],
            :package_name => data["packageName"],
            :protection_level => data["protectionLevel"].to_i,
            :flags => data["flags"].to_i,
            :device_id => device[:id],
          }
        end
      )
    end

    if json["small_files"]
      DB[:small_files].multi_insert(
        json["small_files"].map do |k, v|
          { :path => k, :contents => Base64.decode64(v), :device_id => device[:id] }
        end
      )
    end

    if json["file_permissions"]
      DB[:file_permissions].multi_insert(
        json["file_permissions"].map do |data|
          {
            :path => data['path'],
            :link_path => data['linkPath'],
            :mode => data['mode'],
            :size => data['size'],
            :uid => data['uid'],
            :gid => data['gid'],
            :selinux_context => data['selinuxContext'],
            :device_id => device[:id]
          }
        end
      )
    end

    if json["providers"]
      DB[:content_providers].multi_insert(
        json["providers"].map do |data|
          {
            :authority => data["authority"],
            :init_order => data["initOrder"],
            :multiprocess => data["multiprocess"],
            :grant_uri_permissions => data["grantUriPermissions"],
            :read_permission => data["readPermission"],
            :write_permission => data["writePermission"],
            :path_permissions => data["pathPermissions"],
            :uri_permission_patterns => data["uriPermissionPatterns"],
            :flags => data["flags"],
            :device_id => device[:id]
          }
        end
      )
    end

    if json["environment_variables"]
      DB[:environment_variables].multi_insert(
        json["environment_variables"].map do |k,v|
          { :variable => k, :value => v, :device_id => device[:id] } 
        end
      )
    end

    DB[:results].where(:id => result[:id]).update({:processed => true})
  end
end

get '/process_results' do
  check_production_password(request)
  Thread.new {
    # First things first, delete duplicate entries.
    # { data_sha256_hash => result_id }
    hashes = {}
    DB[:results].all.each { |result|
      hash = Digest::SHA256.digest(result[:data])

      if hashes[hash]
        if result[:processed]
          DB[:results].where(:id => hashes[hash]).delete
          hashes[hash] = result[:id]
        else
          DB[:results].where(:id => result[:id]).delete
        end
      else
        hashes[hash] = result[:id]
      end
    }

    # Now process unprocessed results
    DB[:results].where(:processed => false).each { |result|
      begin
        process_result(result)
      rescue => e
        $stderr.puts e.inspect
        $stderr.puts e.backtrace
      end
    }
  }

  ""
end
