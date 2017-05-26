class Sequel::Model
  def self.display_value(column, value)
    value.to_s
  end
end

DB.create_table?(:results) do
  primary_key :id
  blob        :data, :null => false, :size => 100_000_000 # LZ4-compressed JSON blobs
  boolean     :processed, :null => false
end
class Result < Sequel::Model
end

DB.create_table?(:devices) do
  primary_key :id
  String      :name, :null => false
  String      :build_description, :null => false, :unique => true
end
class Device < Sequel::Model
  one_to_many :system_properties
  one_to_many :sysctls
  one_to_many :environment_variables
  many_to_many :features
  many_to_many :shared_libraries
  one_to_many :permissions
  one_to_many :content_providers
  one_to_many :small_files
  one_to_many :file_permissions
end

DB.create_table?(:system_properties) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :property, :null => false
  blob        :value, :null => false
end
class SystemProperty < Sequel::Model
  many_to_one :device
end

DB.create_table?(:sysctls) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :property, :null => false
  blob        :value, :null => false
end
class Sysctl < Sequel::Model
  many_to_one :device
end

DB.create_table?(:features) do
  primary_key :id
  String      :name, :unique => true, :null => false
end
DB.create_join_table?(:feature_id=>:features, :device_id=>:devices)
class Feature < Sequel::Model
  many_to_many :devices
end

DB.create_table?(:shared_libraries) do
  primary_key :id
  String      :name, :unique => true, :null => false
end
DB.create_join_table?(:shared_library_id=>:shared_libraries, :device_id=>:devices)
class SharedLibrary < Sequel::Model
  many_to_many :devices
end

DB.create_table?(:permissions) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :name, :null => false
  String      :package_name, :null => false
  Integer     :protection_level, :null => false
  Integer     :flags, :null => false
end
class Permission < Sequel::Model
  many_to_one :device

  def self.display_value(column, value)
    case column
    when :protection_level
      level = []

      level << 'development' if (value & 0x20) != 0
      level << 'system' if (value & 0x10) != 0

      case value & 0x0f
        when 0; level << 'normal'
        when 1; level << 'dangerous'
        when 2; level << 'signature'
        when 3; level << 'signatureOrSystem'
        else level << "unknown base #{value & 0x0f}"
      end

      level.join('|')

    when :flags
      if value == 1
        'costsMoney'
      else
        ''
      end

    else
      super(column, value)
    end
  end
end

DB.create_table?(:content_providers) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :authority, :null => false, :length => 512
  Integer     :init_order, :null => false
  boolean     :multiprocess, :null => false
  boolean     :grant_uri_permissions, :null => false
  String      :read_permission
  String      :write_permission
  mediumtext  :path_permissions  # TODO: Currently a JSON-encoded array
  mediumtext  :uri_permission_patterns  # TODO: Currently a JSON-encoded array
  Integer     :flags
end
class ContentProvider < Sequel::Model
  many_to_one :device
end

DB.create_table?(:small_files) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :path, :null => false, :index => true
  blob        :contents, :null => false, :size => 10_000_000
end
class SmallFile < Sequel::Model
  many_to_one :device
end

DB.create_table?(:file_permissions) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :path, :null => false, :index => true
  String      :link_path
  Integer     :mode, :null => false
  Integer     :size, :null => false
  Integer     :uid, :null => false
  Integer     :gid, :null => false
  String      :selinux_context
end
class FilePermission < Sequel::Model
  many_to_one :device

  AID_MAPPING = { 
    0    => "root",
    1000 => "system",
    1001 => "radio",
    1002 => "bluetooth",
    1003 => "graphics",
    1004 => "input",
    1005 => "audio",
    1006 => "camera",
    1007 => "log",
    1008 => "compass",
    1009 => "mount",
    1010 => "wifi",
    1011 => "adb",
    1012 => "install",
    1013 => "media",
    1014 => "dhcp",
    1015 => "sdcard_rw",
    1016 => "vpn",
    1017 => "keystore",
    1018 => "usb",
    1019 => "drm",
    1020 => "mdnsr",
    1021 => "gps",
    1023 => "media_rw",
    1024 => "mtp",
    1026 => "drmrpc",
    1027 => "nfc",
    1028 => "sdcard_r",
    1029 => "clat",
    1030 => "loop_radio",
    2000 => "shell",
    2001 => "cache",
    2002 => "diag",
    3001 => "net_bt_admin",
    3002 => "net_bt",
    3003 => "inet",
    3004 => "net_raw",
    3005 => "net_admin",
    3006 => "net_bw_stats",
    3007 => "net_bw_acct",
    3008 => "net_bt_stack",
    9998 => "misc",
  }

  def self.display_value(column, value)
    case column
    when :uid, :gid
      AID_MAPPING[value] || value.to_s

    when :mode
      sprintf("%o", value)

    when :size
      if value < 1_000
        super(column, value)
      elsif value < 1_000_000
        sprintf("%.1fk", value / 1000.0)
      else
        sprintf("%.1fm", value / 1000000.0)
      end

    else
      super(column, value)
    end
  end
end

DB.create_table?(:environment_variables) do
  primary_key :id
  foreign_key :device_id, :devices
  String      :variable, :null => false
  blob        :value, :null => false
end
class EnvironmentVariable < Sequel::Model
  many_to_one :device
end
