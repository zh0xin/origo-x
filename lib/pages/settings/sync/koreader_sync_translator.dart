import 'package:flutter/widgets.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';
import 'package:xxread/utils/localization_extension.dart';

String koreaderErrorText(BuildContext context, KoreaderSyncErrorCode? code) {
  switch (code) {
    case KoreaderSyncErrorCode.invalidConfiguration:
      return context.l10n.koreaderErrorInvalidConfiguration;
    case KoreaderSyncErrorCode.insecureConnection:
      return context.l10n.koreaderErrorInsecureConnection;
    case KoreaderSyncErrorCode.authentication:
      return context.l10n.koreaderErrorAuthentication;
    case KoreaderSyncErrorCode.usernameTaken:
      return context.l10n.koreaderRegisterUsernameTaken;
    case KoreaderSyncErrorCode.network:
      return context.l10n.koreaderErrorNetwork;
    case KoreaderSyncErrorCode.timeout:
      return context.l10n.koreaderErrorTimeout;
    case KoreaderSyncErrorCode.server:
      return context.l10n.koreaderErrorServer;
    case KoreaderSyncErrorCode.malformedResponse:
      return context.l10n.koreaderErrorServer;
    case KoreaderSyncErrorCode.secureStorage:
      return context.l10n.koreaderErrorSecureStorage;
    case KoreaderSyncErrorCode.localFileRequired:
      return context.l10n.koreaderErrorLocalFileRequired;
    case KoreaderSyncErrorCode.notConfigured:
      return context.l10n.koreaderSyncNotConfigured;
    case KoreaderSyncErrorCode.unknown:
    case null:
      return context.l10n.koreaderErrorUnknown;
  }
}
