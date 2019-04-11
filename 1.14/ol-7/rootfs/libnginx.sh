#!/bin/bash
#
# Bitnami NGINX library

# shellcheck disable=SC1091

# Load Generic Libraries
. /libfile.sh
. /liblog.sh
. /libos.sh
. /libservice.sh
. /libvalidations.sh

# Functions

########################
# Check if NGINX is running
# Globals:
#   NGINX_TMPDIR
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_nginx_running() {
    local pid
    pid=$(get_pid_from_file "${NGINX_TMPDIR}/nginx.pid")

    if [[ -z "$pid" ]]; then
        false
    else
        is_service_running "$pid"
    fi
}

########################
# Stop NGINX
# Globals:
#   NGINX_TMPDIR
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_stop() {
    ! is_nginx_running && return
    debug "Stopping NGINX..."
    stop_service_using_pid "${NGINX_TMPDIR}/nginx.pid"
}

########################
# Start NGINX and wait until it's ready
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_start() {
    is_nginx_running && return
    debug "Starting NGIX..."
    if am_i_root; then
        gosu "${NGINX_DAEMON_USER}" "${NGINX_BASEDIR}/sbin/nginx" -c "${NGINX_CONFDIR}/nginx.conf"
    else
        "${NGINX_BASEDIR}/sbin/nginx" -c "${NGINX_CONFDIR}/nginx.conf"
    fi

    local counter=3
    while ! is_nginx_running ; do
        if [[ "$counter" -ne 0 ]]; then
            break
        fi
        sleep 1;
        counter=$((counter - 1))
    done
}

########################
# Load global variables used on NGINX configuration
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   Series of exports to be used as 'eval' arguments
#########################
nginx_env() {
    cat <<"EOF"
export NGINX_BASEDIR="/opt/bitnami/nginx"
export NGINX_VOLUME="/bitnami/nginx"
export NGINX_EXTRAS_DIR="/opt/bitnami/extra/nginx"
export NGINX_TEMPLATES_DIR="${NGINX_EXTRAS_DIR}/templates"
export NGINX_TMPDIR="${NGINX_BASEDIR}/tmp"
export NGINX_CONFDIR="${NGINX_BASEDIR}/conf"
export NGINX_LOGDIR="${NGINX_BASEDIR}/logs"
export PATH="${NGINX_BASEDIR}/sbin:$PATH"
EOF
}

########################
# Build NGINX default configuration
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_default_config() {
    debug "Rendering 'nginx.conf.tpl' template..."
    render-template "${NGINX_TEMPLATES_DIR}/nginx.conf.tpl" > "${NGINX_CONFDIR}/nginx.conf"
}

########################
# Unset HTTP_PROXY header to protect vs HTTPPOXY vulnerability
# Ref: https://www.digitalocean.com/community/tutorials/how-to-protect-your-server-against-the-httpoxy-vulnerability
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_protect_httpoxy_vuln() {
    debug "Unsetting HTTP_PROXY header..."
    echo '# Unset the HTTP_PROXY header' >> "${NGINX_CONFDIR}/fastcgi_params"
    echo 'fastcgi_param  HTTP_PROXY         "";' >> "${NGINX_CONFDIR}/fastcgi_params"
}

########################
# Prepare directories for users to mount its static files and certificates
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_prepare_directories() {
  # Users can mount their html sites at /app
  mv "${NGINX_BASEDIR}/html" /app
  ln -sf /app "${NGINX_BASEDIR}/html"
  # Users can mount their certificates at /certs
  ln -sf /certs "${NGINX_CONFDIR}/bitnami/certs"
}

########################
# Validate settings in NGINX_* env vars
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_validate() {
    info "Validating settings in NGINX_* env vars..."

    for var in "NGINX_HTTP_PORT_NUMBER" "NGINX_HTTPS_PORT_NUMBER"; do
        local validate_port_args=()
        ! am_i_root && validate_port_args+=("-unprivileged")
        if [[ -n "${!var:-}" ]]; then
            if ! err=$(validate_port "${validate_port_args[@]}" "${!var:-}"); then
                error "An invalid port was specified in the environment variable $var: $err"
                exit 1
            fi
        fi
    done

    for var in "NGINX_DAEMON_USER" "NGINX_DAEMON_GROUP"; do
        if am_i_root; then
            if [[ -z "${!var:-}" ]]; then
                error "The $var environment variable cannot be empty when running as root"
                exit 1
            fi
        else
            if [[ -n "${!var:-}" ]]; then
                warn "The $var environment variable will be ignored when running as non-root"
            fi
        fi
    done
}

########################
# Setup NGINX
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_setup() {
    info "Initializing NGINX..."

    if am_i_root; then
        debug "Ensure NGINX daemon user/group exists..."
        ensure_user_exists "$NGINX_DAEMON_USER" "$NGINX_DAEMON_GROUP"
    fi
    # Persisted configuration files from old versions
    if [[ -f "$NGINX_VOLUME/conf/nginx.conf" ]]; then
        error "A 'nginx.conf' file was found inside '${NGINX_VOLUME}/conf'. This configuration is not supported anymore. Please mount the configuration file at '${NGINX_CONFDIR}/nginx.conf' instead."
        exit 1
    fi
    if ! is_dir_empty "$NGINX_VOLUME/conf/vhosts"; then
        warn "Custom vhosts config files were found in a legacy directory: $NGINX_VOLUME/conf/vhosts"
        warn "  Please use ${NGINX_CONFDIR}/vhosts instead."
        warn "  Please note custom vhosts config files will not be persisted anymore."
        debug "Moving vhosts config files to new location..."
        cp -r "$NGINX_VOLUME/conf/vhosts" "$NGINX_CONFDIR"
    fi
    if am_i_root && [[ -n "${NGINX_DAEMON_USER:-}" ]]; then
        chown "${NGINX_DAEMON_USER:-}" "${NGINX_CONFDIR}" "${NGINX_CONFDIR}/vhosts" "$NGINX_TMPDIR"
    fi

    debug "Updating 'nginx.conf' based on user configuration..."
    if [[ -n "${NGINX_HTTP_PORT_NUMBER:-}" ]]; then
      sed -i -r "s/(listen\s+)8080/\1${NGINX_HTTP_PORT_NUMBER}/g" ${NGINX_CONFDIR}/nginx.conf
    fi
}
