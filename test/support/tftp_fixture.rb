# frozen_string_literal: true

# 继承既有合成完成/失败样本；实际型号及固件 unknown，来源见 fixtures/tftp/README.md。
module TftpFixture
  CASES = {
    cisco_ios: ["router#", "copy running-config tftp:", "1280 bytes copied in 2.1 secs", "copy-complete.cfg"],
    cisco_nxos: ["switch#", "copy running-config tftp://192.0.2.10/success.cfg vrf management", "Copy complete", "success.cfg"],
    h3c: ["<H3C>", "tftp 192.0.2.10 put startup.cfg transfer-complete.cfg", "Transfer complete.", "transfer-complete.cfg"],
    huawei: ["<HUAWEI>", "tftp 192.0.2.10 put startup.cfg transfer-complete.cfg", "Transfer completed successfully", "transfer-complete.cfg"],
    hillstone: ["fw#", "export configuration startup to tftp server 192.0.2.10 vrouter mgt-vr backup.cfg", "Export ok,target file name backup.cfg", "backup.cfg"],
    palo_alto: ["admin@fw>", "tftp export configuration to 192.0.2.10 from running-config.xml", "Sent 983442 bytes in 21.2 seconds", "running-config.xml"],
    radware: [">> Main#", "/cfg/ptcfg 192.0.2.10 -tftp", "Current config successfully tftp'd", "config-uploaded.tgz"]
  }.freeze
end
