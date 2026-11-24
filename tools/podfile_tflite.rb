
# TensorFlow Lite (API C) ne doit être présent qu'une seule fois dans l'application : dans le plugin pencil_bridge.
# CocoaPods le lie aussi dans l'application (Runner) ; on retire de la configuration de Runner l'option qui le lie.
post_integrate do |installer|
  pattern = File.join(installer.sandbox.root.to_s, 'Target Support Files', 'Pods-Runner', 'Pods-Runner.*.xcconfig')
  Dir.glob(pattern).each do |file|
    text = File.read(file).gsub(' -framework "TensorFlowLiteC"', '')
    File.write(file, text)
    puts "TensorFlowLiteC retiré de #{File.basename(file)}"
  end
end
