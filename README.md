# Intel I219-V Ethernet Repair for ASRock Z370 Pro4
This fix is for the following board

```
Base Board Information
        Manufacturer: ASRock
        Product Name: Z370 Pro4
        Version:
        Serial Number: M80-B6011900166
        Asset Tag:
        Features:
                Board is a hosting board
                Board is replaceable
        Location In Chassis:
        Chassis Handle: 0x0003
        Type: Motherboard
        Contained Object Handles: 0

Diginnos, Ubuntu 22.04, kernel 6.8.0-138-generic
PCI Ethernet ID: 8086:15b8
```

## Required Equipment

You will need a USB-C Ethernet dongle to get internet in order to apply the fix.
Yes, I know it's a chicken-and-egg situtation.

You need internet to fix the no internet issue.


## WHAT THIS DOES
The onboard Ethernet controller reports an invalid NVM checksum. The
standard Linux driver refuses to initialize it. This installer applies
a narrowly targeted checksum-bypass patch to the Ubuntu e1000e driver,
compiles and (when Secure Boot is enabled) signs it, installs it and
rebuilds the boot image. This is a workaround, not an NVM repair.

You can check if you have the exact problem via `sudo dmesg | grep -i e1000e`.

If you see exactly this line `e1000e 0000:00:1f.6: The NVM Checksum Is Not Valid` from the following output
```
[    0.792569] e1000e: Intel(R) PRO/1000 Network Driver
[    0.792572] e1000e: Copyright(c) 1999 - 2015 Intel Corporation.
[    0.792605] e1000e 0000:00:1f.6: enabling device (0000 -> 0002)
[    0.792829] e1000e 0000:00:1f.6: Interrupt Throttling Rate (ints/sec) set to dynamic conservative mode
[    1.023270] e1000e 0000:00:1f.6: The NVM Checksum Is Not Valid
[    1.056826] e1000e: probe of 0000:00:1f.6 failed with error -5
```

this fix if for you.

## FIX
1. Open Terminal (Ctrl+Alt+T).
2. Open the folder containing install.sh.
3. Run: sudo bash install.sh
4. When the script says Completed, run: sudo reboot

This will patch the driver.
After the patch, you should see 


## VERIFY AFTER REBOOT

### Check which driver is being loaded
First, check if the patched driver is being loaded via `modinfo -n e1000e`.

If you see
```
/lib/modules/6.8.0-138-generic/updates/e1000e.ko
```
the patch has been applied successfully.

Otherwise if you see
```
/lib/modules/6.8.0-138-generic/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko
```
it is still loading the original driver.



### Check if we have internet now
```
  sudo dmesg | grep -i e1000e
  ip -br addr
  nmcli device status
```


Expected boot log: NVM checksum invalid; continuing for diagnostic test
Expected network interface: enp0s31f6, with an IP address after cable
connection. Confirm web/network access before removing the USB adapter.

ROLLBACK (requires USB Ethernet adapter)
  sudo rm -f /lib/modules/$(uname -r)/updates/e1000e.ko
  sudo depmod -a
  sudo update-initramfs -u -k "$(uname -r)"
  sudo reboot

NOTE: Rollback restores the original driver, which may still reject the
Ethernet controller. Kernel upgrades require a newly built/signed module.
This is a test-specific workaround, not a universal repair.
