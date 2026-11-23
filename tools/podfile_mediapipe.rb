
# MediaPipe ne doit être présent qu'une seule fois dans l'application : dans le plugin pencil_bridge.
# CocoaPods le lie aussi dans l'application (Runner) ; deux copies s'enregistrent deux fois au lancement et MediaPipe s'arrête.
# On retire donc de la configuration de Runner les options qui lient MediaPipe.
post_integrate do |installer|
  pattern = File.join(installer.sandbox.root.to_s, 'Target Support Files', 'Pods-Runner', 'Pods-Runner.*.xcconfig')
  Dir.glob(pattern).each do |file|
    kept = File.readlines(file).reject { |line| line.include?('libMediaPipeTasksCommon_') }
    text = kept.join
    text = text.gsub(' -framework "MediaPipeTasksCommon"', '').gsub(' -framework "MediaPipeTasksVision"', '')
    File.write(file, text)
    puts "MediaPipe retiré de #{File.basename(file)}"
  end
end
