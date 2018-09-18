# Describe the software to run on the infrastructure described by s4-ec2.nix.
{
  network.description = "Zcash server";

  zcashnode =
  { config, pkgs, resources, ... }:
  let zcash = pkgs.callPackage ./zcash/default.nix { };
      s4signupwebsite = pkgs.callPackage ./s4signupwebsite.nix { };
      torControlPort = 9051;
      websiteOnionDir = "/var/lib/tor/onion/signup-website";
      torKeyFile = "/run/keys/signup-website-tor-onion-service.secret";
  in
  # Allow the two Zcash protocol ports.
  { networking.firewall.allowedTCPPorts = [ 18232 18233 ];

    users.users.zcash =
    { isNormalUser = true;
      home = "/var/lib/zcashd";
      description = "Runs a full Zcash node";
    };

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

#     /*
#      * Serve up some static content from a web server at an Onion address.
#      * Nixops has some support for configuring Onion services but not v3
#      * services.  Thus, we do this configuration manually with this config
#      * file blob.
#      */
#     services.tor.extraConfig = ''
# HiddenServiceDir /var/lib/tor/onion/signup-website
# HiddenServiceVersion 3
# HiddenServicePort 80 127.0.0.1:${toString internalSignupHTTPPort}
# '';

    /* Provide a private key for the website Onion service. */
    /* https://elvishjerricco.github.io/2018/06/24/secure-declarative-key-management.html */
    /* https://nixos.org/nixops/manual/#idm140737318276736 */
    deployment.keys."signup-website-tor-onion-service.secret" =
    { keyFile = ./secrets/onion-services/signup-website.secret;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };
    deployment.keys."signup-website-tor-onion-service.public" =
    { keyFile = ./secrets/onion-services/signup-website.public;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };
    deployment.keys."signup-website-tor-onion-service.hostname" =
    { keyFile = ./secrets/onion-services/hostname;
      user = "tor";
      group = "tor";
      permissions = "0600";
    };

    # https://nixos.org/nixos/manual/options.html#opt-systemd.tmpfiles.rules
    systemd.tmpfiles.rules =
    [ "d  ${websiteOnionDir}                       0700 tor tor - -"
      "L+ ${websiteOnionDir}/hs_ed25519_secret_key -    -   -   - ${torKeyFile}"
      "L+ ${websiteOnionDir}/hs_ed25519_public_key -    -   -   - /run/keys/signup-website-tor-onion-service.public"
      "L+ ${websiteOnionDir}/hostname              -    -   -   - /run/keys/signup-website-tor-onion-service.hostname"
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
        --port onion:version=3:public_port=80:controlPort=${toString torControlPort}:hiddenServiceDir=${websiteOnionDir}
      '';
  };
  };
}
