require 'fastlane/action'
require 'fileutils'
require 'os'
require 'json'
require 'digest'
require_relative '../helper/match_keystore_helper'

module Fastlane
  module Actions
    module SharedValues
      MATCH_KEYSTORE_PATH = :MATCH_KEYSTORE_PATH
      MATCH_KEYSTORE_ALIAS_NAME = :MATCH_KEYSTORE_ALIAS_NAME
      MATCH_KEYSTORE_APK_SIGNED = :MATCH_KEYSTORE_APK_SIGNED
    end

    class MatchKeystoreAction < Action

      def self.to_md5(value)
        hash_value = Digest::MD5.hexdigest value
        hash_value
      end

      def self.sha512(value)
        hash_value = Digest::SHA512.hexdigest value
        hash_value
      end

      def self.load_json(json_path)
        file = File.read(json_path)
        data_hash = JSON.parse(file)
        data_hash
      end

      def self.load_properties(properties_filename)
        properties = {}
        File.open(properties_filename, 'r') do |properties_file|
          properties_file.read.each_line do |line|
            line.strip!
            if (line[0] != ?# and line[0] != ?=)
              i = line.index('=')
              if (i)
                properties[line[0..i - 1].strip] = line[i + 1..-1].strip
              else
                properties[line] = ''
              end
            end
          end      
        end
        properties
      end

      def self.get_android_home
        `rm -f android_home.txt`
        `echo $ANDROID_HOME > android_home.txt`
        data = File.read("android_home.txt")
        android_home = data.strip
        `rm -f android_home.txt`
        android_home
      end

      def self.get_build_tools
        android_home = self.get_android_home()
        build_tools_root = File.join(android_home, '/build-tools')

        sub_dirs = Dir.glob(File.join(build_tools_root, '*', ''))
        build_tools_last_version = ''
        for sub_dir in sub_dirs
          build_tools_last_version = sub_dir
        end

        build_tools_last_version
      end
      
      def self.check_openssl_version
        output = `openssl version`
        if !output.start_with?("LibreSSL") && !output.start_with?("OpenSSL")
          raise "Please install OpenSSL 1.1.1 at least https://www.openssl.org/"
        end
        UI.message("OpenSSL version: " + output.strip)
        output.strip
      end

      def self.is_libre_ssl
        result false
        output = `openssl version`
        if output.start_with?("LibreSSL")
          result = true
        end
        result
      end

      def self.gen_key(key_path, password)
        `rm -f '#{key_path}'`
        shaValue = self.sha512(password)
        `echo "#{shaValue}" > '#{key_path}'`
        # `echo "#{password}" | openssl dgst -sha512 | awk '{print $2}' | cut -c1-128 > '#{key_path}'`
      end

      def self.encrypt_file(clear_file, encrypt_file, key_path)
        `rm -f '#{encrypt_file}'`
        `openssl enc -aes-256-cbc -salt -pbkdf2 -in '#{clear_file}' -out '#{encrypt_file}' -pass file:'#{key_path}'`
      end

      def self.decrypt_file(encrypt_file, clear_file, key_path)
        `rm -f '#{clear_file}'`
        `openssl enc -d -aes-256-cbc -pbkdf2 -in '#{encrypt_file}' -out '#{clear_file}' -pass file:'#{key_path}'`
      end

      def self.assert_equals(test_name, excepted, value)
        puts "Unit Test: #{test_name}"
        if value != excepted
          puts " - Excepted: #{excepted}"
          puts " - Returned: #{value}"
          raise "Unit Test - #{test_name} error!"
        else
          puts " - OK"
        end
      end

      def self.test_security
        self.check_openssl_version

        fakeValue = "4esfsf4dsfds!efs5ZDOJF"
        # Check MD5
        md5value = self.to_md5(fakeValue)
        excepted = "1c815cd208fe08076c9e7b6595d121d1"
        self.assert_equals("MD5", excepted, md5value)

        # Check SHA-512
        shaValue = self.sha512(fakeValue)
        excepted = "cc6a7b0d89cc61c053f7018a305672bdb82bc07e5015f64bb063d9662be4ec81ec8afa819b009de266482b6bd56b7068def2524c32f5b5d4d9db49ee4578499d"
        self.assert_equals("SHA-512", excepted, shaValue)

        # Check SHA-512-File
        tempKeyPath = File.join(Dir.pwd, '/temp/key.txt')
        self.gen_key(tempKeyPath, fakeValue)
        shaValue = self.get_file_content(tempKeyPath).strip!
        excepted = "cc6a7b0d89cc61c053f7018a305672bdb82bc07e5015f64bb063d9662be4ec81ec8afa819b009de266482b6bd56b7068def2524c32f5b5d4d9db49ee4578499d"
        self.assert_equals("SHA-512-File", excepted, shaValue)
        File.delete(tempKeyPath)

        
        
      end

      def self.sign_apk(apk_path, keystore_path, key_password, alias_name, alias_password, zip_align)

        build_tools_path = self.get_build_tools()
        UI.message("Build-tools path: #{build_tools_path}")

        # https://developer.android.com/studio/command-line/zipalign
        if zip_align == true
          apk_path_aligned = apk_path.gsub(".apk", "-aligned.apk")
          `rm -f '#{apk_path_aligned}'`
          UI.message("Aligning APK (zipalign): #{apk_path_aligned}")
          `#{build_tools_path}zipalign -f -v 4 '#{apk_path}' '#{apk_path_aligned}'`

          if !File.file?(apk_path_aligned)
            raise "Aligned APK not exsits!"
          end
        else
          UI.message("No zip align!")
          apk_path_aligned = apk_path
        end
        apk_path_signed = apk_path.gsub(".apk", "-signed.apk")
        apk_path_signed = apk_path_signed.gsub("unsigned", "")
        apk_path_signed = apk_path_signed.gsub("--", "-")

        # https://developer.android.com/studio/command-line/apksigner
        `rm -f '#{apk_path_signed}'`
        `#{build_tools_path}apksigner sign --ks '#{keystore_path}' --ks-key-alias '#{alias_name}' --ks-pass pass:'#{key_password}' --key-pass pass:'#{alias_password}' --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false --out '#{apk_path_signed}' '#{apk_path_aligned}'`
        
        `#{build_tools_path}apksigner verify '#{apk_path_signed}'`
        `rm -f '#{apk_path_aligned}'`

        apk_path_signed
      end 

      def self.resolve_dir(path)
        if !File.directory?(path)
          path = File.join(Dir.pwd, path)
        end
        path
      end

      def self.resolve_file(path)
        if !File.file?(path)
          path = File.join(Dir.pwd, path)
        end
        path
      end

      def self.get_file_content(file_path)
        data = File.read(file_path)
        data
      end

      def self.resolve_apk_path(apk_path)

        # Set default APK path if not set:
        if apk_path.to_s.strip.empty?
          apk_path = '/app/build/outputs/apk/'
        end

        if !apk_path.to_s.end_with?(".apk") 

          apk_path = self.resolve_dir(apk_path)

          pattern = File.join(apk_path, '*.apk')
          files = Dir[pattern]

          for file in files
            if file.to_s.end_with?(".apk") && !file.to_s.end_with?("-signed.apk")  
              apk_path = file
              break
            end
          end

        else
          apk_path = self.resolve_file(apk_path)
        end
        
        apk_path
      end

      def self.prompt2(params)
        # UI.message("prompt2: #{params[:value]}")
        if params[:value].to_s.empty?
          return_value = other_action.prompt(text: params[:text], secure_text: params[:secure_text], ci_input: params[:ci_input])
        else
          return_value = params[:value]
        end
        return_value
      end

      def self.run(params)

        # Get input parameters:
        git_url = params[:git_url]
        package_name = params[:package_name]
        apk_path = params[:apk_path]
        existing_keystore = params[:existing_keystore]
        match_secret = params[:match_secret]
        override_keystore = params[:override_keystore]
        keystore_data = params[:keystore_data]
        clear_keystore = params[:clear_keystore]
        unit_test = params[:unit_test]

        # Test OpenSSL/LibreSSL
        if unit_test
          result_test = self.test_security
          exit!
        end

        # Init constants:
        keystore_name = 'keystore.jks'
        properties_name = 'keystore.properties'
        keystore_info_name = 'keystore.txt'
        properties_encrypt_name = 'keystore.properties.enc'

        # Check Android Home env:
        android_home = self.get_android_home()
        UI.message("Android SDK: #{android_home}")
        if android_home.to_s.strip.empty?
          raise "The environment variable ANDROID_HOME is not defined, or Android SDK is not installed!"
        end

        # Check OpenSSL:
        self.check_openssl_version

        # Init workign local directory:
        dir_name = ENV['HOME'] + '/.match_keystore'
        unless File.directory?(dir_name)
          UI.message("Creating '.match_keystore' working directory...")
          FileUtils.mkdir_p(dir_name)
        end

        # Init 'security password' for AES encryption:
        key_name = "#{self.to_md5(git_url)}.hex"
        key_path = File.join(dir_name, key_name)
        # UI.message(key_path)
        if !File.file?(key_path)
          security_password = self.prompt2(text: "Security password: ", secure_text: true, value: match_secret)
          if security_password.to_s.strip.empty?
            raise "Security password is not defined! Please use 'match_secret' parameter for CI."
          end
          UI.message "Generating security key '#{key_name}'..."
          self.gen_key(key_path, security_password)
        end

        # Check is 'security password' is well initialized:
        tmpkey = self.get_file_content(key_path).strip
        if tmpkey.length == 128
          UI.message "Security key '#{key_name}' initialized"
        else
          raise "The security key '#{key_name}' is malformed, or not initialized!"
        end

        # Clear repo Keystore (local) - mostly for testing:
        repo_dir = File.join(dir_name, self.to_md5(git_url))
        if clear_keystore && File.directory?(repo_dir)
          FileUtils.rm_rf(repo_dir)
          UI.message("Local repo keystore (#{repo_dir}) directory deleted!")
        end

        # Create repo directory to sync remote Keystores repository:
        unless File.directory?(repo_dir)
          UI.message("Creating 'repo' directory...")
          FileUtils.mkdir_p(repo_dir)
        end

        # Check if package name defined:
        if package_name.to_s.strip.empty?
          raise "Package name is not defined!"
        end

        # Define paths:
        keystoreAppDir = File.join(repo_dir, package_name)
        keystore_path = File.join(keystoreAppDir, keystore_name)
        properties_path = File.join(keystoreAppDir, properties_name)
        properties_encrypt_path = File.join(keystoreAppDir, properties_encrypt_name)

        # Cloning/pulling GIT remote repository:
        gitDir = File.join(repo_dir, '/.git')
        if !File.directory?(gitDir)
          UI.message("Cloning remote Keystores repository...")
          puts ''
          `git clone #{git_url} #{repo_dir}`
          puts ''
        else
          UI.message("Pulling remote Keystores repository...")
          puts ''
          `cd #{repo_dir} && git pull`
          puts ''
        end

        # Load parameters from JSON for CI or Unit Tests:
        if keystore_data != nil && File.file?(keystore_data)
          data_json = self.load_json(keystore_data)
          data_key_password = data_json['key_password']
          data_alias_name = data_json['alias_name']
          data_alias_password = data_json['alias_password']
          data_full_name = data_json['full_name']
          data_org_unit = data_json['org_unit']
          data_org = data_json['org']
          data_city_locality = data_json['city_locality']
          data_state_province = data_json['state_province']
          data_country = data_json['country']
        end

        # Create keystore with command
        override_keystore = !existing_keystore.to_s.strip.empty? && File.file?(existing_keystore)
        UI.message("Existing Keystore: #{existing_keystore}")
        if !File.file?(keystore_path) || override_keystore 

          if File.file?(keystore_path)
            FileUtils.remove_dir(keystore_path)
          end

          key_password = self.prompt2(text: "Keystore Password: ", value: data_key_password)
          if key_password.to_s.strip.empty?
            raise "Keystore Password is not definined!"
          end
          alias_name = self.prompt2(text: "Keystore Alias name: ", value: data_alias_name)
          if alias_name.to_s.strip.empty?
            raise "Keystore Alias name is not definined!"
          end
          alias_password = self.prompt2(text: "Keystore Alias password: ", value: data_alias_password)
          if alias_password.to_s.strip.empty?
            raise "Keystore Alias password is not definined!"
          end

          # https://developer.android.com/studio/publish/app-signing
          if existing_keystore.to_s.strip.empty? || !File.file?(existing_keystore)
            UI.message("Generating Android Keystore...")
            
            full_name = self.prompt2(text: "Certificate First and Last Name: ", value: data_full_name)
            org_unit = self.prompt2(text: "Certificate Organisation Unit: ", value: data_org_unit)
            org = self.prompt2(text: "Certificate Organisation: ", value: data_org)
            city_locality = self.prompt2(text: "Certificate City or Locality: ", value: data_city_locality) 
            state_province = self.prompt2(text: "Certificate State or Province: ", value: data_state_province)
            country = self.prompt2(text: "Certificate Country Code (XX): ", value: data_country)
            
            keytool_parts = [
              "keytool -genkey -v",
              "-keystore '#{keystore_path}'",
              "-alias '#{alias_name}'",
              "-keyalg RSA -keysize 2048 -validity 10000",
              "-storepass '#{alias_password}'",
              "-keypass '#{key_password}'",
              "-dname \"CN=#{full_name}, OU=#{org_unit}, O=#{org}, L=#{city_locality}, S=#{state_province}, C=#{country}\"",
            ]
            sh keytool_parts.join(" ")
          else
            UI.message("Copy existing keystore to match_keystore repository...") 
            `cp #{existing_keystore} #{keystore_path}`
          end

          UI.message("Generating Keystore properties...")
         
          if File.file?(properties_path)
            FileUtils.remove_dir(properties_path)
          end
        
          # Build URL:
          store_file = git_url + '/' + package_name + '/' + keystore_name

          out_file = File.new(properties_path, "w")
          out_file.puts("keyFile=#{store_file}")
          out_file.puts("keyPassword=#{key_password}")
          out_file.puts("aliasName=#{alias_name}")
          out_file.puts("aliasPassword=#{alias_password}")
          out_file.close

          self.encrypt_file(properties_path, properties_encrypt_path, key_path)
          File.delete(properties_path)

          # Print Keystore data in repo:
          keystore_info_path = File.join(keystoreAppDir, keystore_info_name)
          `yes "" | keytool -list -v -keystore '#{keystore_path}' -storepass '#{key_password}' > '#{keystore_info_path}'`
          
          UI.message("Upload new Keystore to remote repository...")
          puts ''
          `cd '#{repo_dir}' && git add .`
          `cd '#{repo_dir}' && git commit -m "[ADD] Keystore for app '#{package_name}'."`
          `cd '#{repo_dir}' && git push`
          puts ''

        else  
          UI.message "Keystore file already exists, continue..."

          self.decrypt_file(properties_encrypt_path, properties_path, key_path)

          properties = self.load_properties(properties_path)
          key_password = properties['keyPassword']
          alias_name = properties['aliasName']
          alias_password = properties['aliasPassword']

          File.delete(properties_path)
        end

        # Resolve path to the APK to sign:
        output_signed_apk = ''
        apk_path = self.resolve_apk_path(apk_path)

        # Sign APK:
        if File.file?(apk_path)
          UI.message("APK to sign: " + apk_path)

          if File.file?(keystore_path)

            UI.message("Signing the APK...")
            puts ''
            output_signed_apk = self.sign_apk(
              apk_path, 
              keystore_path, 
              key_password, 
              alias_name, 
              alias_password, 
              true # Zip align
            )
            puts ''
          end 
        else
          UI.message("No APK file found to sign!")
        end

        # Prepare contect shared values for next lanes:
        Actions.lane_context[SharedValues::MATCH_KEYSTORE_PATH] = keystore_path
        Actions.lane_context[SharedValues::MATCH_KEYSTORE_ALIAS_NAME] = alias_name
        Actions.lane_context[SharedValues::MATCH_KEYSTORE_APK_SIGNED] = output_signed_apk

        output_signed_apk
      end

      def self.description
        "Easily sync your Android keystores across your team"
      end

      def self.authors
        ["Christopher NEY"]
      end

      def self.return_value
        "Prepare Keystore local path, alias name, and passwords for the specified App."
      end

      def self.output
        [
          ['MATCH_KEYSTORE_PATH', 'File path of the Keystore fot the App.'],
          ['MATCH_KEYSTORE_ALIAS_NAME', 'Keystore Alias Name.'],
          ['MATCH_KEYSTORE_APK_SIGNED', 'Path of the signed APK.']
        ]
      end

      def self.details
        # Optional:
        "This way, your entire team can use the same account and have one code signing identity without any manual work or confusion."
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :git_url,
                                   env_name: "MATCH_KEYSTORE_GIT_URL",
                                description: "The URL of the Git repository (Github, BitBucket...)",
                                   optional: false,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :package_name,
                                   env_name: "MATCH_KEYSTORE_PACKAGE_NAME",
                                description: "The package name of the App",
                                   optional: false,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :apk_path,
                                   env_name: "MATCH_KEYSTORE_APK_PATH",
                                description: "Path of the APK file to sign",
                                   optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :match_secret,
                                   env_name: "MATCH_KEYSTORE_SECRET",
                                description: "Secret to decrypt keystore.properties file (CI)",
                                   optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :existing_keystore,
                                   env_name: "MATCH_KEYSTORE_EXISTING",
                                description: "Path of an existing Keystore",
                                   optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :override_keystore,
                                   env_name: "MATCH_KEYSTORE_OVERRIDE",
                                description: "Override an existing Keystore (false by default)",
                                   optional: true,
                                       type: Boolean),
          FastlaneCore::ConfigItem.new(key: :keystore_data,
                                   env_name: "MATCH_KEYSTORE_JSON_PATH",
                                description: "Required data to import an existing keystore, or create a new one",
                                   optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :clear_keystore,
                                   env_name: "MATCH_KEYSTORE_CLEAR",
                                description: "Clear the local keystore (false by default)",
                                   optional: true,
                                       type: Boolean),
          FastlaneCore::ConfigItem.new(key: :unit_test,
                                  env_name: "MATCH_KEYSTORE_UNIT_TESTS",
                                description: "launch Unit Tests (false by default)",
                                  optional: true,
                                      type: Boolean)
        ]
      end

      def self.is_supported?(platform)
        # Adjust this if your plugin only works for a particular platform (iOS vs. Android, for example)
        # See: https://docs.fastlane.tools/advanced/#control-configuration-by-lane-and-by-platform
        [:android].include?(platform)
      end
    end
  end
end
