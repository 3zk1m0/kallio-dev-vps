# Warn before the provider's monthly transfer allowance runs out.
{ pkgs, vars, ... }:

let
  monthlyLimitGB = 1000;
  alertAtPercent = 70;
in
{
  services.vnstat.enable = true;

  systemd.services.bandwidth-alert = {
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ vnstat iproute2 curl ];
    script = ''
      iface=$(ip -o -4 route show default | awk '{ print $5; exit }')

      # output 3 = print only when over limit, exit 5 = status 2 when over
      # limit, so a real vnstat failure (status 1) stays distinguishable.
      status=0
      report=$(vnstat -i "$iface" --alert 3 5 m total \
        ${toString (monthlyLimitGB * alertAtPercent / 100)} GB) || status=$?
      if [ "$status" -ne 2 ]; then exit "$status"; fi

      curl -sSf \
        -u "alerter:$(cat /var/lib/ntfy/alerter-password)" \
        -H "Title: VPS traffic past ${toString alertAtPercent}% of ${toString monthlyLimitGB} GB" \
        -H "Tags: warning" \
        -d "$report" \
        https://${vars.ntfyDomain}/alerts
    '';
  };

  systemd.timers.bandwidth-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
