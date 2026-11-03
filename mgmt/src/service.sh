#!/bin/bash

# Type=simple can report active before listener initialization has completed.
wait_service_ready() {
    local attempt
    for attempt in 1 2 3; do
        sleep 1
        systemctl is-active --quiet "$1" || return 1
    done
    return 0
}
