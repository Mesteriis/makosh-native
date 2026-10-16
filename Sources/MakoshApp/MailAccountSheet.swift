import SwiftUI
import MakoshMail

struct MailAccountSheet: View {
    @ObservedObject var model: MailWorkspaceModel
    let account: MailAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var accountID=UUID().uuidString
    @State private var populated=false
    @State private var name=""
    @State private var email=""
    @State private var imapHost=""
    @State private var imapPort=993
    @State private var imapSecurity=MailConnectionSecurity.tls
    @State private var imapUser=""
    @State private var smtpHost=""
    @State private var smtpPort=465
    @State private var smtpSecurity=MailConnectionSecurity.tls
    @State private var smtpUser=""
    @State private var imapPassword=""
    @State private var smtpPassword=""
    @State private var samePassword=true
    var body: some View {
        VStack(spacing:0) {
            HStack { VStack(alignment:.leading,spacing:5) { Text(account == nil ? "Добавить почту" : "Настройки почты").font(.title2.bold());Text("Ручное подключение IMAP / SMTP").foregroundStyle(.secondary) };Spacer();Button("Закрыть") { dismiss() }.disabled(model.busy) }.padding(24)
            Divider()
            Form {
                Section("Аккаунт") {
                    TextField("Имя отправителя",text:$name).accessibilityIdentifier("mail.account.name")
                    TextField("Адрес почты",text:$email).accessibilityIdentifier("mail.account.email")
                }
                Section("Входящая почта · IMAP") {
                    TextField("Сервер",text:$imapHost).accessibilityIdentifier("mail.account.imapHost")
                    HStack { TextField("Порт",value:$imapPort,format:.number.grouping(.never)).frame(width:140);Picker("Защита",selection:$imapSecurity) { Text("TLS").tag(MailConnectionSecurity.tls);Text("STARTTLS").tag(MailConnectionSecurity.startTLS) } }
                    TextField("Имя пользователя",text:$imapUser)
                    SecureField("Пароль приложения",text:$imapPassword).accessibilityIdentifier("mail.account.imapPassword")
                }
                Section("Исходящая почта · SMTP") {
                    TextField("Сервер",text:$smtpHost).accessibilityIdentifier("mail.account.smtpHost")
                    HStack { TextField("Порт",value:$smtpPort,format:.number.grouping(.never)).frame(width:140);Picker("Защита",selection:$smtpSecurity) { Text("TLS").tag(MailConnectionSecurity.tls);Text("STARTTLS").tag(MailConnectionSecurity.startTLS) } }
                    TextField("Имя пользователя",text:$smtpUser)
                    Toggle("Использовать пароль IMAP",isOn:$samePassword)
                    if !samePassword { SecureField("Пароль приложения SMTP",text:$smtpPassword) }
                }
                Text("Пароли сохраняются в Связке ключей. TLS проверяет сертификат и имя сервера. При смене адреса, сервера или пользователя будет создан отдельный аккаунт; прежняя переписка и операции сохранят свою идентичность.").font(.caption).foregroundStyle(.secondary)
                if let error=model.error { Text(error).foregroundStyle(.red).font(.callout) }
            }.formStyle(.grouped).disabled(model.busy || model.synthetic)
            Divider()
            HStack { if model.busy { ProgressView().controlSize(.small);Text("Подключение…") };Spacer();Button("Отмена") { dismiss() }.disabled(model.busy);Button("Подключить") { connect() }.buttonStyle(.borderedProminent).disabled(model.busy || model.synthetic || email.isEmpty || (account == nil && imapPassword.isEmpty)).accessibilityIdentifier("mail.account.connect") }.padding(20)
        }.frame(width:580,height:760)
        .onAppear {
            guard !populated else { return }; populated=true; model.error=nil
            if let account {
                accountID=account.id;name=account.displayName;email=account.email
                imapHost=account.imapHost;imapPort=account.imapPort;imapSecurity=account.imapSecurity;imapUser=account.imapUsername
                smtpHost=account.smtpHost;smtpPort=account.smtpPort;smtpSecurity=account.smtpSecurity;smtpUser=account.smtpUsername
            }
        }
        .onChange(of:email) { old,value in if imapUser.isEmpty || imapUser==old { imapUser=value };if smtpUser.isEmpty || smtpUser==old { smtpUser=value } }
        .onChange(of:imapSecurity) { _,value in imapPort=value == .tls ? 993 : 143 }
        .onChange(of:smtpSecurity) { _,value in smtpPort=value == .tls ? 465 : 587 }
    }
    private func connect() {
        var value=MailAccount(id:accountID,displayName:name,email:email,imapHost:imapHost,imapPort:imapPort,imapSecurity:imapSecurity,imapUsername:imapUser,smtpHost:smtpHost,smtpPort:smtpPort,smtpSecurity:smtpSecurity,smtpUsername:smtpUser)
        if let account, !account.sameSource(as: value) { value.id = UUID().uuidString }
        guard value.id == accountID || !imapPassword.isEmpty else { model.error = "Для нового источника введите его пароль приложения."; return }
        Task { await model.add(value,imapPassword:imapPassword.isEmpty ? nil : imapPassword,smtpPassword:(samePassword ? imapPassword : smtpPassword).isEmpty ? nil : (samePassword ? imapPassword : smtpPassword));imapPassword="";smtpPassword="" }
    }
}
