module ArrTop
  # Command-line entry point. (Scaffold — argument parsing, queue polling, the
  # TUI, and the import-file disk-watch land in follow-up work.)
  module CLI
    def self.run(argv : Array(String)) : Nil
      puts "arrtop #{ArrTop::VERSION}"
      puts "not yet implemented — scaffold only."
    end
  end
end
