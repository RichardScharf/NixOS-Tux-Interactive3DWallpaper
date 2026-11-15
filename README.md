# NixOS-Tux-Interactive3DWallpaper
Interactive NixOS Wallpaper I promptgrammed to enhance my KDE Plasma Desktop.

## [Try it out by clicking here](https://richardscharf.github.io/NixOS-Tux-Interactive3DWallpaper/nixos_tux_interactive_3d_wallpaper.html)

### Usage
- you can interact with it using mouse movements, clicks and the scoll wheel.
- you can also toggle the different wallpapers / overlays at the top (pinned hud)
- settings gives you more granular control over the different styles, pins and bindings

<img width="3840" height="2160" alt="Screenshot" src="https://github.com/user-attachments/assets/8a6058ec-98d1-4d67-970f-f35a19572095" />


## Features:
- Interact with your wallpaper using your mouse and scroll wheel
- Battery sensitive pause/resume logic settings
<img width="880" height="762" alt="image" src="https://github.com/user-attachments/assets/c096d2a4-1c75-4252-9309-c386095677f1" />


## How to install:
If you're on NixOS you can just place it in the same folder as your main configuration.nix file (usually /etc/nixos) and then import it like this:

_(place this line inside configuration.nix file:)_

``imports = [
./wallpaperPlugin.nix
];``

then run `sudo nixos-rebuild switch`, reboot into the new configuration and then you can go into the Wallpaper Settings of KDE Plasma (by right clicking on an empty space on your desktop and selecting "Desktop and Wallpaper", or pressing Ctrl+Shift+D) and then you should see and select the Wallpaper type: ``NixOS WebGL Wallpaper``

There you can paste the path to the nixos_tux_interactive_3d_wallpaper.html file. For example:


file:///home/YOURUSERNAME/Downloads/red_nixos_tux_3d_interactive_scene.html
