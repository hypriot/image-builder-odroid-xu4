require 'serverspec'
set :backend, :exec

def image_path
  return "hypriotos-odroid-xu4-#{ENV['VERSION']}.img"
end

def run( cmd )
  return command("guestfish add #{image_path} : run : #{cmd}")
end

def run_mounted( cmd )
  return run("mount /dev/sda2 / : #{cmd}")
end
