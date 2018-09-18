# Describe the software to run on the infrastructure described by s4-ec2.nix.
{
  network.description = "Zcash server";

  zcashnode =
  { lib, pkgs, ... }:
  let zcash = pkgs.callPackage ./zcash/default.nix { };
      s4signupwebsite = pkgs.callPackage ./s4signupwebsite.nix { };
      torControlPort = 9051;
      websiteOnion2Dir = "/run/onion/v2/signup-website";
      websiteOnion3Dir = "/run/onion/v3/signup-website";
  in
  # Allow the two Zcash protocol ports.
  { networking.firewall.allowedTCPPorts = [ 18232 18233 ];

    users.users.zcash =
    { isNormalUser = true;
      home = "/var/lib/zcashd";
      description = "Runs a full Zcash node";
    };

    /*
     * Nix-generated Tor configuration file has a `User tor` that we cannot
     * easily control.  This option sets the UID *and* GID of the Tor process.
     * The keys we want to pass to Tor for the website configuration are in
     * /run/keys which is group-readable and group-owned by `keys`.  So, get
     * the tor user's primary group to be the keys group so it can actually
     * read the keys.
     *
     * We have to force this value to override the previously supplied value.
     *
     * Note that this means the tor user no longer belongs to the tor group.
     * This may break something but if it does I haven't yet observed it.
     *
     * This is kind of lame, I think.  Maybe it would be better not to have
     * keys on the disk or something?
     */
    users.users.tor.group = lib.mkForce "keys";

    environment.systemPackages = [
      zcash
      # Provides flock, required by zcash-fetch-params.  Probably a Nix Zcash
      # package bug that we have to specify it.
      pkgs.utillinux
      # Also required by zcash-fetch-params.
      pkgs.wget
    ];

    systemd.services.zcashd =
      # Write the Zcashd configuration file and remember where it is for
      # later.
      let conf = pkgs.writeText "zcash.conf"
      ''
      # Operate on the test network while we're in development.
      testnet=1
      addnode=testnet.z.cash

      # Don't be a miner.
      gen=0
    '';
    in
    { unitConfig.Documentation = "https://z.cash/";
      description = "Zcashd running a non-mining Zcash full node";
      # Get it to start as a part of the normal boot process.
      wantedBy    = [ "multi-user.target" ];

      # Get zcash-fetch-params dependencies into its PATH.
      path = [ pkgs.utillinux pkgs.wget ];

      serviceConfig = {
        Restart                 = "on-failure";
        User                    = "zcash";
        # Nice                    = 19;
        # IOSchedulingClass       = "idle";
        PrivateTmp              = "yes";
        # PrivateNetwork          = "yes";
        # NoNewPrivileges         = "yes";
        # ReadWriteDirectories    = "${zcash}/bin /var/lib/zcashd";
        # InaccessibleDirectories = "/home";
        StateDirectory          = "zcashd";

        # Parameters are required before a node can start.  These are fetched
        # from the network.  This only needs to happen once.  Currently we try
        # to do it every time we're about to start the node.  Maybe this can
        # be improved.
        ExecStartPre            = "${zcash}/bin/zcash-fetch-params";

        # Rely on $HOME to set the location of most Zcashd inputs.  The
        # configuration file is an exception as it lives in the store.
        ExecStart               = "${zcash}/bin/zcashd -conf=${conf}";
      };
    };

    /*
     * Run a Tor node so we can operate a hidden service to allow user signup.
     */
    services.tor.enable = true;
    /*
     * We don't make outgoing Tor connections via the SOCKS proxy.
     */
    services.tor.client.socksPolicy = "reject *";

    /*
     * Enable the control port so that we can do interesting things with the
     * daemon from other programs.
     */
    services.tor.controlPort = torControlPort;

    services.tor.extraConfig = ''
      # Enable authentication on the ControlPort via a secret shared cookie.
      CookieAuthentication 1
    '';

    /*
     * Customize the Tor service so that it is able to read the keys with which
     * we will supply it.
     */
    systemd.services.tor =
    { serviceConfig =
      { ReadWritePaths =
        [ "/var/lib/tor"
        ];
      };
    };

    /* Provide a private key for the website Onion service. */
    /* https://elvishjerricco.github.io/2018/06/24/secure-declarative-key-management.html */
    /* https://nixos.org/nixops/manual/#idm140737318276736 */
    deployment.keys."signup-website-tor-onion-service-v3.secret" =
    { keyFile = ./secrets/onion-services/v3/signup-website.secret;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };
    deployment.keys."signup-website-tor-onion-service-v3.public" =
    { keyFile = ./secrets/onion-services/v3/signup-website.public;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };
    deployment.keys."signup-website-tor-onion-service-v3.hostname" =
    { keyFile = ./secrets/onion-services/v3/hostname;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };

    deployment.keys."signup-website-tor-onion-service-v2.private_key" =
    { keyFile = ./secrets/onion-services/v2/signup-website.private_key;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };
    deployment.keys."signup-website-tor-onion-service-v2.hostname" =
    { keyFile = ./secrets/onion-services/v2/hostname;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };

    # https://nixos.org/nixos/manual/options.html#opt-systemd.tmpfiles.rules
    systemd.tmpfiles.rules =
    [ "d  ${websiteOnion3Dir}                       0700 tor tor - -"
      "L+ ${websiteOnion3Dir}/hs_ed25519_secret_key -    -   -   - /run/keys/signup-website-tor-onion-service-v3.secret"
      "L+ ${websiteOnion3Dir}/hs_ed25519_public_key -    -   -   - /run/keys/signup-website-tor-onion-service-v3.public"
      "L+ ${websiteOnion3Dir}/hostname              -    -   -   - /run/keys/signup-website-tor-onion-service-v3.hostname"

      "d  /run/onion                                0700 tor tor - -"
      "d  /run/onion/v2                             0700 tor tor - -"
      "d  ${websiteOnion2Dir}                       0700 tor tor - -"
      "L+ ${websiteOnion2Dir}/private_key           -    -   -   - /run/keys/signup-website-tor-onion-service-v2.private_key"
      "L+ ${websiteOnion2Dir}/hostname              -    -   -   - /run/keys/signup-website-tor-onion-service-v2.hostname"
    ];

    /*
     * Operate a static website allowing user signup, exposed via the Tor
     * hidden service.
     */
    systemd.services."signup-website" =
    { unitConfig.Documentation = "https://leastauthority.com/";
      description = "The S4 2.0 signup website.";

      path = [ (pkgs.python27.withPackages (ps: [ ps.twisted ps.txtorcon ])) ];

      # Get it to start as a part of the normal boot process.
      wantedBy    = [ "multi-user.target" ];

      # Make sure Tor is up and our keys are available.
      after = [ "tor.service" "signup-website-tor-onion-service.secret-key.service" ];
      wants = [ "tor.service" "signup-website-tor-onion-service.secret-key.service" ];

      script = ''
      twist --log-format=text web \
        --path ${s4signupwebsite} \
        --port onion:version=3:public_port=80:controlPort=${toString torControlPort}:hiddenServiceDir=${websiteOnion3Dir}
      '';
  };
  };
}
