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
  # Parties du corps (cheveux, peau, vêtements) : TensorFlow Lite, API C (Google, Apache 2.0 ; bibliothèque dynamique) fait tourner le modèle MediaPipe
  # « selfie multiclasse » (Google, Apache 2.0, 16 Mo, mis dans Assets/). Essai : à terme, modèle téléchargé à la première utilisation.
  s.dependency 'TensorFlowLiteC', '2.17.0'
  s.resources        = ['Assets/*.tflite']
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
