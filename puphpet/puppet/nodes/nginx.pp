if $yaml_values == undef { $yaml_values = loadyaml('/vagrant/puphpet/config.yaml') }
if $nginx_values == undef { $nginx_values = $yaml_values['nginx'] }
if $php_values == undef { $php_values = hiera_hash('php', false) }
if $hhvm_values == undef { $hhvm_values = hiera_hash('hhvm', false) }

include puphpet::params

if hash_key_equals($nginx_values, 'install', 1) {
  include nginx::params

  Class['puphpet::ssl_cert']
  -> Nginx::Resource::Vhost <| |>

  class { 'puphpet::ssl_cert': }

  $webroot_location     = $puphpet::params::nginx_webroot_location
  $nginx_provider_types = [
    'virtualbox',
    'vmware_fusion',
    'vmware_desktop',
    'parallels'
  ]

  exec { "mkdir -p ${webroot_location}":
    creates => $webroot_location,
  }

  if downcase($::provisioner_type) in $nginx_provider_types {
    $webroot_location_group = 'www-data'
    $vhost_docroot_group    = undef
  } else {
    $webroot_location_group = undef
    $vhost_docroot_group    = 'www-user'
  }

  if ! defined(File[$webroot_location]) {
    file { $webroot_location:
      ensure  => directory,
      group   => $webroot_location_group,
      mode    => 0775,
      require => [
        Exec["mkdir -p ${webroot_location}"],
        Group['www-data']
      ],
    }
  }

  if hash_key_equals($hhvm_values, 'install', 1) {
    $fcgi_string = "127.0.0.1:${hhvm_values['settings']['port']}"
  } elsif hash_key_equals($php_values, 'install', 1) {
    $fcgi_string = '127.0.0.1:9000'
  } else {
    $fcgi_string = false
  }

  if $::osfamily == 'redhat' {
    file { '/usr/share/nginx':
      ensure  => directory,
      mode    => 0775,
      owner   => 'www-data',
      group   => 'www-data',
      require => Group['www-data'],
      before  => Package['nginx']
    }
  }

  if hash_key_equals($hhvm_values, 'install', 1)
    or hash_key_equals($php_values, 'install', 1)
  {
    $default_vhost = {
      'server_name'    => '_',
      'server_aliases' => [],
      'www_root'       => '/var/www/html',
      'listen_port'    => 80,
      'location'       => '\.php$',
      'index_files'    => ['index', 'index.html', 'index.htm', 'index.php'],
      'envvars'        => [],
      'ssl'            => '0',
      'ssl_cert'       => '',
      'ssl_key'        => '',
      'engine'         => 'php',
    }
  } else {
    $default_vhost = {
      'server_name'    => '_',
      'server_aliases' => [],
      'www_root'       => '/var/www/html',
      'listen_port'    => 80,
      'location'       => '/',
      'index_files'    => ['index', 'index.html', 'index.htm'],
      'envvars'        => [],
      'ssl'            => '0',
      'ssl_cert'       => '',
      'ssl_key'        => '',
      'engine'         => false,
    }
  }

  class { 'nginx': }

  if hash_key_equals($nginx_values['settings'], 'default_vhost', 1) {
    $nginx_vhosts = merge($nginx_values['vhosts'], {
      'default' => $default_vhost,
    })

    if ! defined(File[$puphpet::params::nginx_default_conf_location]) {
      file { $puphpet::params::nginx_default_conf_location:
        ensure  => absent,
        require => Package['nginx'],
        notify  => Class['nginx::service'],
      }
    }
  } else {
    $nginx_vhosts = $nginx_values['vhosts']
  }

  if count($nginx_vhosts) > 0 {
    each( $nginx_vhosts ) |$key, $vhost| {
      exec { "exec mkdir -p ${vhost['www_root']} @ key ${key}":
        command => "mkdir -p ${vhost['www_root']}",
        creates => $vhost['www_root'],
      }

      if ! defined(File[$vhost['www_root']]) {
        file { $vhost['www_root']:
          ensure  => directory,
          group   => $vhost_docroot_group,
          mode    => 0765,
          require => [
            Exec["exec mkdir -p ${vhost['www_root']} @ key ${key}"],
            Group['www-user']
          ]
        }
      }

      if ! defined(Firewall["100 tcp/${vhost['listen_port']}"]) {
        firewall { "100 tcp/${vhost['listen_port']}":
          port   => $vhost['listen_port'],
          proto  => tcp,
          action => 'accept',
        }
      }
    }

    create_resources(nginx_vhost, $nginx_vhosts)
  }

  if ! defined(Firewall['100 tcp/443']) {
    firewall { '100 tcp/443':
      port   => 443,
      proto  => tcp,
      action => 'accept',
    }
  }
}

define nginx_vhost (
  $server_name,
  $server_aliases   = [],
  $www_root,
  $listen_port,
  $location,
  $index_files,
  $envvars          = [],
  $ssl              = false,
  $ssl_cert         = $puphpet::params::ssl_cert_location,
  $ssl_key          = $puphpet::params::ssl_key_location,
  $ssl_port         = '443',
  $rewrite_to_https = false,
  $spdy             = $nginx::params::nx_spdy,
  $engine           = false,
){
  $merged_server_name = concat([$server_name], $server_aliases)

  if is_array($index_files) and count($index_files) > 0 {
    $try_files_prepend = $index_files[count($index_files) - 1]
  } else {
    $try_files_prepend = ''
  }

  if $engine == 'php' {
    $try_files               = "${try_files_prepend} /index.php\$is_args\$args"
    $fastcgi_split_path_info = '^(.+\.php)(/.*)$'
    $fastcgi_index           = 'index.php'
    $fastcgi_param           = concat([
      'SCRIPT_FILENAME /var/www/$site/$sub/$fastcgi_script_name'
    ], $envvars)
    $fastcgi_pass_hash       = value_true($fcgi_string) ? { true => {'fastcgi_pass' => 'unix:/var/run/php5-fpm.sock'}, default => {} }
  } else {
    $try_files               = "${try_files_prepend} /index.html"
    $fastcgi_split_path_info = '^(.+\.html)(/.+)$'
    $fastcgi_index           = 'index.html'
    $fastcgi_param           = $envvars
    $fastcgi_pass_hash       = {}
  }

  $ssl_set              = value_true($ssl)              ? { true => true,      default => false, }
  $ssl_cert_set         = value_true($ssl_cert)         ? { true => $ssl_cert, default => $puphpet::params::ssl_cert_location, }
  $ssl_key_set          = value_true($ssl_key)          ? { true => $ssl_key,  default => $puphpet::params::ssl_key_location, }
  $ssl_port_set         = value_true($ssl_port)         ? { true => $ssl_port, default => '443', }
  $rewrite_to_https_set = value_true($rewrite_to_https) ? { true => true,      default => false, }
  $spdy_set             = value_true($spdy)             ? { true => on,        default => off, }

  $location_cfg_append  = merge({
    'fastcgi_split_path_info' => $fastcgi_split_path_info,
    'fastcgi_param'           => $fastcgi_param,
    'fastcgi_index'           => $fastcgi_index,
    'include'                 => 'fastcgi_params'
  }, $fastcgi_pass_hash)

  nginx::resource::vhost { $server_name:
    server_name      => $merged_server_name,
    www_root         => $www_root,
    listen_port      => $listen_port,
    index_files      => $index_files,
    try_files        => ['$uri', '$uri/', "${try_files}"],
    ssl              => $ssl_set,
    ssl_cert         => $ssl_cert_set,
    ssl_key          => $ssl_key_set,
    ssl_port         => $ssl_port_set,
    rewrite_to_https => $rewrite_to_https_set,
    spdy             => $spdy_set,
    vhost_cfg_append => {sendfile => 'off'}
  }

  if $engine == 'php' {
    nginx::resource::location { "${server_name}-php":
      ensure              => present,
      vhost               => $server_name,
      location            => "~ ${location}",
      proxy               => undef,
      ssl                 => $ssl_set,
      www_root            => $www_root,
      location_cfg_append => $location_cfg_append,
      notify              => Class['nginx::service'],
    }
  }
}

