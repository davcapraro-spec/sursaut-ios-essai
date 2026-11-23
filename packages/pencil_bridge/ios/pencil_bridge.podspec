Pod::Spec.new do |s|
  s.name             = 'pencil_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Pont Apple Pencil pour Sursaut iPad.'
  s.description      = 'Lit le roulis, le serrage, le double appui et le survol de l Apple Pencil.'
  s.homepage         = 'https://github.com/davcapraro-spec/sursaut-ios-essai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Sursaut' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.frameworks = 'ImageCaptureCore', 'Vision'
  s.source_files     = 'Classes/**/*'
  # Moteur Rust (étape 1) : fabriqué par le workflow, copié ici avant la compilation.
  s.vendored_libraries = 'libsursaut_engine.a'
  # LibRaw est du C++ : la bibliothèque standard du C++ doit être liée à l'application.
  s.libraries = 'c++'
  s.dependency 'Flutter'
  # Maillage du visage à 478 points (Google, Apache 2.0). Le modèle « face_landmarker.task » est mis dans Assets/ par le workflow.
  s.dependency 'MediaPipeTasksVision'
  s.resources        = ['Assets/*.task']
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
