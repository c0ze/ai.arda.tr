//// Translated UI strings and quick-topic prompts. EN/JP were ported 1:1 from
//// the `translations` object in the old `public/script.js`; TR was added
//// natively in the Lustre port.

pub type Language {
  En
  Jp
  Tr
}

pub type Strings {
  Strings(
    header_title: String,
    construct_title: String,
    construct_subline: String,
    status_ready: String,
    status_thinking: String,
    status_writing: String,
    welcome_msg: String,
    input_placeholder: String,
    disclaimer: String,
    who_you: String,
    who_construct: String,
    btn_experience: String,
    btn_education: String,
    btn_skills: String,
    btn_visa: String,
    btn_about_bot: String,
    prompt_experience: String,
    prompt_education: String,
    prompt_skills: String,
    prompt_visa: String,
    prompt_about_bot: String,
  )
}

pub fn strings(language: Language) -> Strings {
  case language {
    En ->
      Strings(
        header_title: "Arda's AI Construct",
        construct_title: "Ask the construct",
        construct_subline: "answers questions about Arda's work, projects and music, and passes messages on to him",
        status_ready: "ready",
        status_thinking: "thinking…",
        status_writing: "writing…",
        welcome_msg: "I answer questions about Arda's work, projects, education and music. If you have a job for him, send me the details and I will pass them on.",
        input_placeholder: "Ask about Arda",
        disclaimer: "Answers can be wrong. Check anything important with Arda.",
        who_you: "you ▸",
        who_construct: "construct ▸",
        btn_experience: "Experience",
        btn_education: "Education",
        btn_skills: "Skills",
        btn_visa: "Visa status",
        btn_about_bot: "About this bot",
        prompt_experience: "Where has Arda worked?",
        prompt_education: "Where did Arda study?",
        prompt_skills: "What are Arda's technical skills?",
        prompt_visa: "What is Arda's visa status in Japan?",
        prompt_about_bot: "How was this assistant built?",
      )
    Jp ->
      Strings(
        header_title: "ArdaのAIコンストラクト",
        construct_title: "コンストラクトに聞く",
        construct_subline: "Ardaの仕事・プロジェクト・音楽についての質問に答え、Ardaへの伝言も取り次ぎます",
        status_ready: "待機中",
        status_thinking: "考え中…",
        status_writing: "応答中…",
        welcome_msg: "Ardaの仕事、プロジェクト、学歴、音楽についての質問に答えます。Ardaに仕事の話があれば、詳細を送ってください。本人に伝えます。",
        input_placeholder: "Ardaについて質問する",
        disclaimer: "回答が間違っていることがあります。重要なことはArdaに確認してください。",
        who_you: "あなた ▸",
        who_construct: "construct ▸",
        btn_experience: "経歴",
        btn_education: "学歴",
        btn_skills: "スキル",
        btn_visa: "ビザステータス",
        btn_about_bot: "このボットについて",
        prompt_experience: "Ardaはどこで働いてきましたか？",
        prompt_education: "Ardaはどこで学びましたか？",
        prompt_skills: "Ardaの技術的なスキルは何ですか？",
        prompt_visa: "Ardaの日本でのビザステータスはどうなっていますか？",
        prompt_about_bot: "このアシスタントはどのように作られましたか？",
      )
    Tr ->
      Strings(
        header_title: "Arda'nın AI Konstrüktü",
        construct_title: "Konstrükte sor",
        construct_subline: "Arda'nın işi, projeleri ve müziği hakkındaki soruları yanıtlar, mesajınızı Arda'ya iletir",
        status_ready: "hazır",
        status_thinking: "düşünüyor…",
        status_writing: "yazıyor…",
        welcome_msg: "Arda'nın işi, projeleri, eğitimi ve müziği hakkındaki soruları yanıtlıyorum. Arda için bir iş teklifiniz varsa ayrıntıları gönderin, ona iletirim.",
        input_placeholder: "Arda hakkında soru sorun",
        disclaimer: "Yanıtlar hatalı olabilir. Önemli bilgileri Arda'yla teyit edin.",
        who_you: "siz ▸",
        who_construct: "construct ▸",
        btn_experience: "Deneyim",
        btn_education: "Eğitim",
        btn_skills: "Yetenekler",
        btn_visa: "Vize durumu",
        btn_about_bot: "Bot hakkında",
        prompt_experience: "Arda nerelerde çalıştı?",
        prompt_education: "Arda nerede okudu?",
        prompt_skills: "Arda'nın teknik yetenekleri neler?",
        prompt_visa: "Arda'nın Japonya'daki vize durumu nedir?",
        prompt_about_bot: "Bu asistan nasıl geliştirildi?",
      )
  }
}
