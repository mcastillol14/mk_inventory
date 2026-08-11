fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'maka'
description 'Inventario completo (F2) + barra rápida (Tab, antes mk_weaponwheel) con NUI propia — reemplaza a esx_inventory, dispara los mismos eventos ya probados de es_extended'
version '2.0.0'

shared_script '@es_extended/imports.lua'

shared_scripts {
    'config.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/weapons/*.png',
}

dependencies {
    'es_extended',
}
