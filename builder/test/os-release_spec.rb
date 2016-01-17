require 'serverspec'
set :backend, :exec

describe "Root filesystem" do
  let(:rootfs_path) { return '/build' }

  it "exists" do
    rootfs_dir = file(rootfs_path)

    expect(rootfs_dir).to exist
  end

  context "Hypriot OS Release in /etc/os-release" do
    let(:stdout) { command("cat #{rootfs_path}/etc/os-release").stdout }

    it "has a HYPRIOT_OS= entry" do
      expect(stdout).to contain('^HYPRIOT_OS=')
    end
    it "has a HYPRIOT_TAG= entry" do
      expect(stdout).to contain('^HYPRIOT_TAG=')
    end
    it "has a HYPRIOT_DEVICE= entry" do
      expect(stdout).to contain('^HYPRIOT_DEVICE=')
    end

    it "is for architecure 'HYPRIOT_OS=\"HypriotOS/armhf\"'" do
      expect(stdout).to contain('^HYPRIOT_OS="HypriotOS/armhf"$')
    end

    it "is for device 'HYPRIOT_DEVICE=\"ODROID XU4\"'" do
      expect(stdout).to contain('^HYPRIOT_DEVICE="ODROID XU4"$')
    end

  end
end
