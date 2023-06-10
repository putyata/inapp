import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_store_server_sdk/app_store_server_sdk.dart';
// import 'package:firebase_backend_dart/app_store_purchase_handler.dart';

import 'package:googleapis/androidpublisher/v3.dart' as ap;
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:googleapis/pubsub/v1.dart' as pubsub;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:shelf/shelf_io.dart';
import 'package:googleapis/firestore/v1.dart';

const androidPackageId = 'com.way2.me';
const appStoreIssuerId = '';
const appStoreKeyId = '';
const appStoreSharedSecret = '';
const bundleId = 'me.way2';
const googlePlayProjectName = '';
const googlePlayPubsubBillingTopic = 'play_billing';

Future<Map<String, PurchaseHandler>> _createPurchaseHandlers() async {
  // Configure Android Publisher API access
  final serviceAccountGooglePlay = File('assets/service-account-google-play.json').readAsStringSync();
  final clientCredentialsGooglePlay = auth.ServiceAccountCredentials.fromJson(serviceAccountGooglePlay);
  final clientGooglePlay = await auth.clientViaServiceAccount(clientCredentialsGooglePlay, [
    ap.AndroidPublisherApi.androidpublisherScope,
    pubsub.PubsubApi.cloudPlatformScope,
  ]);
  final androidPublisher = ap.AndroidPublisherApi(clientGooglePlay);

  // Pub/Sub API to receive on purchase events from Google Play
  final pubsubApi = pubsub.PubsubApi(clientGooglePlay);

  // Configure Firestore API access
  final serviceAccountFirebase = File('assets/service-account-firebase.json').readAsStringSync();
  final clientCredentialsFirebase = auth.ServiceAccountCredentials.fromJson(serviceAccountFirebase);
  final clientFirebase = await auth.clientViaServiceAccount(clientCredentialsFirebase, [
    fs.FirestoreApi.cloudPlatformScope,
  ]);
  final firestoreApi = fs.FirestoreApi(clientFirebase);
  final dynamic json = jsonDecode(serviceAccountFirebase);
  final projectId = json['project_id'] as String;
  final iapRepository = IapRepository(firestoreApi, projectId);

  final subscriptionKeyAppStore = File('assets/SubscriptionKey.p8').readAsStringSync();

  // Configure Apple Store API access
  var appStoreEnvironment = AppStoreEnvironment.sandbox(
    bundleId: bundleId,
    issuerId: appStoreIssuerId,
    keyId: appStoreKeyId,
    privateKey: subscriptionKeyAppStore,
  );

  // Stored token for Apple Store API access, if available
  final file = File('assets/appstore.token');
  String? appStoreToken;
  if (file.existsSync() && file.lengthSync() > 0) {
    appStoreToken = file.readAsStringSync();
  }

  final appStoreServerAPI = AppStoreServerAPI(
    AppStoreServerHttpClient(
      appStoreEnvironment,
      jwt: appStoreToken,
      jwtTokenUpdatedCallback: (token) {
        file.writeAsStringSync(token);
      },
    ),
  );

  return {
    'google_play': GooglePlayPurchaseHandler(
      androidPublisher,
      iapRepository,
      pubsubApi,
    ),
    'app_store': AppStorePurchaseHandler(
      iapRepository,
      appStoreServerAPI,
    ),
  };
}

Future<void> main() async {
  final router = Router();

  final purchaseHandlers = await _createPurchaseHandlers();

  /// Warning: This endpoint has no security
  /// and does not implement user authentication.
  /// Production applications should implement authentication.
  // ignore: avoid_types_on_closure_parameters
  router.post('/verifypurchase', (Request request) async {
    final dynamic payload = json.decode(await request.readAsString());

    // NOTE: userId should be obtained using authentication methods.
    // source from PurchaseDetails.verificationData.source
    // productData product data based on the productId
    // token from PurchaseDetails.verificationData.serverVerificationData
    final (:userId, :source, :productData, :token) = getPurchaseData(payload);

    // Will call to verifyPurchase on
    // [GooglePlayPurchaseHandler] or [AppleStorePurchaseHandler]
    final result = await purchaseHandlers[source]!.verifyPurchase(
      userId: userId,
      productData: productData,
      token: token,
    );

    if (result) {
      // Note: Better success response recommended
      return Response.ok('all good!');
    } else {
      // Note: Better error handling recommended
      return Response.internalServerError();
    }
  });

  // Start service
  await serveHandler(router);
}

({
  String userId,
  String source,
  ProductData productData,
  String token,
}) getPurchaseData(dynamic payload) {
  if (payload
      case {
        'userId': String userId,
        'source': String source,
        'productId': String productId,
        'verificationData': String token,
      }) {
    return (
      userId: userId,
      source: source,
      productData: productDataMap[productId]!,
      token: token,
    );
  } else {
    throw const FormatException('Unexpected JSON');
  }
}

class GooglePlayPurchaseHandler extends PurchaseHandler {
  final ap.AndroidPublisherApi androidPublisher;
  final IapRepository iapRepository;
  final pubsub.PubsubApi pubsubApi;

  GooglePlayPurchaseHandler(
    this.androidPublisher,
    this.iapRepository,
    this.pubsubApi,
  ) {
    // Poll messages from Pub/Sub every 10 seconds
    Timer.periodic(Duration(seconds: 10), (_) {
      _pullMessageFromPubSub();
    });
  }

  /// Handle non-subscription purchases (one time purchases).
  ///
  /// Retrieves the purchase status from Google Play and updates
  /// the Firestore Database accordingly.
  @override
  Future<bool> handleNonSubscription({
    required String? userId,
    required ProductData productData,
    required String token,
  }) async {
    print(
      'GooglePlayPurchaseHandler.handleNonSubscription'
      '($userId, ${productData.productId}, ${token.substring(0, 5)}...)',
    );

    try {
      // Verify purchase with Google
      final response = await androidPublisher.purchases.products.get(
        androidPackageId,
        productData.productId,
        token,
      );

      print('Purchases response: ${response.toJson()}');

      // Make sure an order id exists
      if (response.orderId == null) {
        print('Could not handle purchase without order id');
        return false;
      }
      final orderId = response.orderId!;

      final purchaseData = NonSubscriptionPurchase(
        purchaseDate: DateTime.fromMillisecondsSinceEpoch(
          int.parse(response.purchaseTimeMillis ?? '0'),
        ),
        orderId: orderId,
        productId: productData.productId,
        status: NonSubscriptionStatus.values[response.purchaseState ?? 0],
        userId: userId,
        iapSource: IAPSource.googleplay,
      );

      // Update the database
      if (userId != null) {
        // If we know the userId,
        // update the existing purchase or create it if it does not exist.
        await iapRepository.createOrUpdatePurchase(purchaseData);
      } else {
        // If we do not know the user id, a previous entry must already
        // exist, and thus we'll only update it.
        await iapRepository.updatePurchase(purchaseData);
      }
      return true;
    } on ap.DetailedApiRequestError catch (e) {
      print(
        'Error on handle NonSubscription: $e\n'
        'JSON: ${e.jsonResponse}',
      );
    } catch (e) {
      print('Error on handle NonSubscription: $e\n');
    }
    return false;
  }

  /// Handle subscription purchases.
  ///
  /// Retrieves the purchase status from Google Play and updates
  /// the Firestore Database accordingly.
  @override
  Future<bool> handleSubscription({
    required String? userId,
    required ProductData productData,
    required String token,
  }) async {
    print(
      'GooglePlayPurchaseHandler.handleSubscription'
      '($userId, ${productData.productId}, ${token.substring(0, 5)}...)',
    );

    try {
      // Verify purchase with Google
      final response = await androidPublisher.purchases.subscriptions.get(
        androidPackageId,
        productData.productId,
        token,
      );

      print('Subscription response: ${response.toJson()}');

      // Make sure an order id exists
      if (response.orderId == null) {
        print('Could not handle purchase without order id');
        return false;
      }
      final orderId = extractOrderId(response.orderId!);

      final purchaseData = SubscriptionPurchase(
        purchaseDate: DateTime.fromMillisecondsSinceEpoch(
          int.parse(response.startTimeMillis ?? '0'),
        ),
        orderId: orderId,
        productId: productData.productId,
        status: subscriptionStatusFrom(response.paymentState),
        userId: userId,
        iapSource: IAPSource.googleplay,
        expiryDate: DateTime.fromMillisecondsSinceEpoch(
          int.parse(response.expiryTimeMillis ?? '0'),
        ),
      );

      // Update the database
      if (userId != null) {
        // If we know the userId,
        // update the existing purchase or create it if it does not exist.
        await iapRepository.createOrUpdatePurchase(purchaseData);
      } else {
        // If we do not know the user id, a previous entry must already
        // exist, and thus we'll only update it.
        await iapRepository.updatePurchase(purchaseData);
      }
      return true;
    } on ap.DetailedApiRequestError catch (e) {
      print(
        'Error on handle Subscription: $e\n'
        'JSON: ${e.jsonResponse}',
      );
    } catch (e) {
      print('Error on handle Subscription: $e\n');
    }
    return false;
  }

  /// Process messages from Google Play
  /// Called every 10 seconds
  Future<void> _pullMessageFromPubSub() async {
    print('Polling Google Play messages');
    final request = pubsub.PullRequest(
      maxMessages: 1000,
    );
    final topicName = 'projects/$googlePlayProjectName/subscriptions/$googlePlayPubsubBillingTopic-sub';
    final pullResponse = await pubsubApi.projects.subscriptions.pull(
      request,
      topicName,
    );
    final messages = pullResponse.receivedMessages ?? [];
    for (final message in messages) {
      final data64 = message.message?.data;
      if (data64 != null) {
        await _processMessage(data64, message.ackId);
      }
    }
  }

  Future<void> _processMessage(String data64, String? ackId) async {
    final dataRaw = utf8.decode(base64Decode(data64));
    print('Received data: $dataRaw');
    final dynamic data = jsonDecode(dataRaw);
    if (data['testNotification'] != null) {
      print('Skip test messages');
      if (ackId != null) {
        await _ackMessage(ackId);
      }
      return;
    }
    final dynamic subscriptionNotification = data['subscriptionNotification'];
    final dynamic oneTimeProductNotification = data['oneTimeProductNotification'];
    if (subscriptionNotification != null) {
      print('Processing Subscription');
      final subscriptionId = subscriptionNotification['subscriptionId'] as String;
      final purchaseToken = subscriptionNotification['purchaseToken'] as String;
      final productData = productDataMap[subscriptionId]!;
      final result = await handleSubscription(
        userId: null,
        productData: productData,
        token: purchaseToken,
      );
      if (result && ackId != null) {
        await _ackMessage(ackId);
      }
    } else if (oneTimeProductNotification != null) {
      print('Processing NonSubscription');
      final sku = oneTimeProductNotification['sku'] as String;
      final purchaseToken = oneTimeProductNotification['purchaseToken'] as String;
      final productData = productDataMap[sku]!;
      final result = await handleNonSubscription(
        userId: null,
        productData: productData,
        token: purchaseToken,
      );
      if (result && ackId != null) {
        await _ackMessage(ackId);
      }
    } else {
      print('invalid data');
    }
  }

  /// ACK Messages from Pub/Sub
  Future<void> _ackMessage(String id) async {
    print('ACK Message');
    final request = pubsub.AcknowledgeRequest(
      ackIds: [id],
    );
    final subscriptionName = 'projects/$googlePlayProjectName/subscriptions/$googlePlayPubsubBillingTopic-sub';
    await pubsubApi.projects.subscriptions.acknowledge(
      request,
      subscriptionName,
    );
  }
}

/// If a subscription suffix is present (..#) extract the orderId.
String extractOrderId(String orderId) {
  final orderIdSplit = orderId.split('..');
  if (orderIdSplit.isNotEmpty) {
    orderId = orderIdSplit[0];
  }
  return orderId;
}

/// Generic purchase handler,
/// must be implemented for Google Play and Apple Store
abstract class PurchaseHandler {
  /// Verify if purchase is valid and update the database
  Future<bool> verifyPurchase({
    required String userId,
    required ProductData productData,
    required String token,
  }) async {
    switch (productData.type) {
      case ProductType.subscription:
        return handleSubscription(
          userId: userId,
          productData: productData,
          token: token,
        );
      case ProductType.nonSubscription:
        return handleNonSubscription(
          userId: userId,
          productData: productData,
          token: token,
        );
    }
  }

  /// Verify if non-subscription purchase (aka consumable) is valid
  /// and update the database
  Future<bool> handleNonSubscription({
    required String userId,
    required ProductData productData,
    required String token,
  });

  /// Verify if subscription purchase (aka non-consumable) is valid
  /// and update the database
  Future<bool> handleSubscription({
    required String userId,
    required ProductData productData,
    required String token,
  });
}

class ProductData {
  final String productId;
  final ProductType type;

  const ProductData(this.productId, this.type);
}

enum ProductType {
  subscription,
  nonSubscription,
}

const productDataMap = {
  'dash_consumable_2k': ProductData(
    'dash_consumable_2k',
    ProductType.nonSubscription,
  ),
  'dash_upgrade_3d': ProductData(
    'dash_upgrade_3d',
    ProductType.nonSubscription,
  ),
  'dash_subscription_doubler': ProductData(
    'dash_subscription_doubler',
    ProductType.subscription,
  ),
};

enum IAPSource {
  googleplay,
  appstore,
}

abstract class Purchase {
  final IAPSource iapSource;
  final String orderId;
  final String productId;
  final String? userId;
  final DateTime purchaseDate;
  final ProductType type;

  const Purchase({
    required this.iapSource,
    required this.orderId,
    required this.productId,
    required this.userId,
    required this.purchaseDate,
    required this.type,
  });

  Map<String, Value> toDocument() {
    return {
      'iapSource': Value(stringValue: iapSource.name),
      'orderId': Value(stringValue: orderId),
      'productId': Value(stringValue: productId),
      'userId': Value(stringValue: userId),
      'purchaseDate': Value(timestampValue: purchaseDate.toUtc().toIso8601String()),
      'type': Value(stringValue: type.name),
    };
  }

  Map<String, Value> updateDocument();

  static Purchase fromDocument(Document e) {
    final type = ProductType.values.firstWhere((element) => element.name == e.fields!['type']!.stringValue);
    switch (type) {
      case ProductType.subscription:
        return SubscriptionPurchase(
          iapSource: e.fields!['iapSource']!.stringValue == 'googleplay' ? IAPSource.googleplay : IAPSource.appstore,
          orderId: e.fields!['orderId']!.stringValue!,
          productId: e.fields!['productId']!.stringValue!,
          userId: e.fields!['userId']!.stringValue,
          purchaseDate: DateTime.parse(e.fields!['purchaseDate']!.timestampValue!),
          status: SubscriptionStatus.values.firstWhere((element) => element.name == e.fields!['status']!.stringValue),
          expiryDate: DateTime.tryParse(e.fields!['expiryDate']?.timestampValue ?? '') ?? DateTime.now(),
        );
      case ProductType.nonSubscription:
        return NonSubscriptionPurchase(
          iapSource: e.fields!['iapSource']!.stringValue == 'googleplay' ? IAPSource.googleplay : IAPSource.appstore,
          orderId: e.fields!['orderId']!.stringValue!,
          productId: e.fields!['productId']!.stringValue!,
          userId: e.fields!['userId']!.stringValue,
          purchaseDate: DateTime.parse(e.fields!['purchaseDate']!.timestampValue!),
          status: NonSubscriptionStatus.values.firstWhere((element) => element.name == e.fields!['status']!.stringValue),
        );
    }
  }
}

enum NonSubscriptionStatus {
  pending,
  completed,
  cancelled,
}

enum SubscriptionStatus { pending, active, expired }

SubscriptionStatus subscriptionStatusFrom(int? state) {
  return switch (state) {
    // Payment pending
    0 => SubscriptionStatus.pending,
    // Payment received
    1 => SubscriptionStatus.active,
    // Free trial
    2 => SubscriptionStatus.active,
    // Pending deferred upgrade/downgrade
    3 => SubscriptionStatus.pending,
    // Expired or cancelled
    _ => SubscriptionStatus.expired,
  };
}

class NonSubscriptionPurchase extends Purchase {
  final NonSubscriptionStatus status;

  NonSubscriptionPurchase({
    required super.iapSource,
    required super.orderId,
    required super.productId,
    required super.userId,
    required super.purchaseDate,
    required this.status,
    super.type = ProductType.nonSubscription,
  });

  @override
  Map<String, Value> toDocument() {
    final doc = super.toDocument();
    doc.addAll({
      'status': Value(stringValue: status.name),
    });
    return doc;
  }

  @override
  Map<String, Value> updateDocument() {
    return {
      'status': Value(stringValue: status.name),
    };
  }

  @override
  String toString() {
    return 'NonSubscriptionPurchase { '
        'iapSource: $iapSource, '
        'orderId: $orderId, '
        'productId: $productId, '
        'userId: $userId, '
        'purchaseDate: $purchaseDate, '
        'status: $status, '
        'type: $type '
        '}';
  }
}

class SubscriptionPurchase extends Purchase {
  final SubscriptionStatus status;
  final DateTime expiryDate;

  SubscriptionPurchase({
    required super.iapSource,
    required super.orderId,
    required super.productId,
    required super.userId,
    required super.purchaseDate,
    required this.status,
    required this.expiryDate,
    super.type = ProductType.subscription,
  });

  @override
  Map<String, Value> toDocument() {
    final doc = super.toDocument();
    doc.addAll({
      'expiryDate': Value(timestampValue: expiryDate.toUtc().toIso8601String()),
      'status': Value(stringValue: status.name),
    });
    return doc;
  }

  @override
  Map<String, Value> updateDocument() {
    return {
      'status': Value(stringValue: status.name),
    };
  }

  @override
  String toString() {
    return 'SubscriptionPurchase { '
        'iapSource: $iapSource, '
        'orderId: $orderId, '
        'productId: $productId, '
        'userId: $userId, '
        'purchaseDate: $purchaseDate, '
        'status: $status, '
        'expiryDate: $expiryDate, '
        'type: $type '
        '}';
  }
}

class IapRepository {
  final FirestoreApi api;
  final String projectId;

  IapRepository(this.api, this.projectId);

  Future<void> createOrUpdatePurchase(Purchase purchaseData) async {
    print('Updating $purchaseData');
    final purchaseId = _purchaseId(purchaseData);
    await api.projects.databases.documents.commit(
      CommitRequest(
        writes: [
          Write(
            update: Document(fields: purchaseData.toDocument(), name: 'projects/$projectId/databases/(default)/documents/purchases/$purchaseId'),
          ),
        ],
      ),
      'projects/$projectId/databases/(default)',
    );
  }

  Future<void> updatePurchase(Purchase purchaseData) async {
    print('Updating $purchaseData');
    final purchaseId = _purchaseId(purchaseData);
    await api.projects.databases.documents.commit(
      CommitRequest(
        writes: [
          Write(
            update: Document(fields: purchaseData.updateDocument(), name: 'projects/$projectId/databases/(default)/documents/purchases/$purchaseId'),
            updateMask: DocumentMask(fieldPaths: ['status']),
          ),
        ],
      ),
      'projects/$projectId/databases/(default)',
    );
  }

  String _purchaseId(Purchase purchaseData) {
    return '${purchaseData.iapSource.name}_${purchaseData.orderId}';
  }

  Future<List<Purchase>> getPurchases() async {
    final list = await api.projects.databases.documents.list(
      'projects/$projectId/databases/(default)/documents',
      'purchases',
    );

    List<Purchase> purchases = [];
    list.documents!.forEach((element) {
      if (element.fields!.containsKey('type')) {
        purchases.add(Purchase.fromDocument(element));
      }
    });
    return purchases;
  }
}

/// Serves [handler] on [InternetAddress.anyIPv4] using the port returned by
/// [listenPort].
///
/// The returned [Future] will complete using [terminateRequestFuture] after
/// closing the server.
Future<void> serveHandler(Handler handler) async {
  final port = listenPort();

  final server = await serve(
    handler,
    InternetAddress.anyIPv4, // Allows external connections
    port,
  );
  print('Serving at http://${server.address.host}:${server.port}');

  await terminateRequestFuture();

  await server.close();
}

/// Returns the port to listen on from environment variable or uses the default
/// `8080`.
///
/// See https://cloud.google.com/run/docs/reference/container-contract#port
int listenPort() => int.parse(Platform.environment['PORT'] ?? '8080');

/// Returns a [Future] that completes when the process receives a
/// [ProcessSignal] requesting a shutdown.
///
/// [ProcessSignal.sigint] is listened to on all platforms.
///
/// [ProcessSignal.sigterm] is listened to on all platforms except Windows.
Future<void> terminateRequestFuture() {
  final completer = Completer<bool>.sync();

  // sigIntSub is copied below to avoid a race condition - ignoring this lint
  // ignore: cancel_subscriptions
  StreamSubscription? sigIntSub, sigTermSub;

  Future<void> signalHandler(ProcessSignal signal) async {
    print('Received signal $signal - closing');

    final subCopy = sigIntSub;
    if (subCopy != null) {
      sigIntSub = null;
      await subCopy.cancel();
      sigIntSub = null;
      if (sigTermSub != null) {
        await sigTermSub!.cancel();
        sigTermSub = null;
      }
      completer.complete(true);
    }
  }

  sigIntSub = ProcessSignal.sigint.watch().listen(signalHandler);

  // SIGTERM is not supported on Windows. Attempting to register a SIGTERM
  // handler raises an exception.
  if (!Platform.isWindows) {
    sigTermSub = ProcessSignal.sigterm.watch().listen(signalHandler);
  }

  return completer.future;
}

/// Handles App Store purchases.
/// Uses the ITunes API to validate purchases.
/// Uses the App Store Server SDK to obtain the latest subscription status.
class AppStorePurchaseHandler extends PurchaseHandler {
  final IapRepository iapRepository;
  final AppStoreServerAPI appStoreServerAPI;

  AppStorePurchaseHandler(
    this.iapRepository,
    this.appStoreServerAPI,
  ) {
    // Poll Subscription status every 10 seconds.
    Timer.periodic(Duration(seconds: 10), (_) {
      _pullStatus();
    });
  }

  final _iTunesAPI = ITunesApi(
    ITunesHttpClient(
      ITunesEnvironment.sandbox(),
      loggingEnabled: true,
    ),
  );

  @override
  Future<bool> handleNonSubscription({
    required String userId,
    required ProductData productData,
    required String token,
  }) {
    return handleValidation(userId: userId, token: token);
  }

  @override
  Future<bool> handleSubscription({
    required String userId,
    required ProductData productData,
    required String token,
  }) {
    return handleValidation(userId: userId, token: token);
  }

  /// Handle purchase validation.
  Future<bool> handleValidation({
    required String userId,
    required String token,
  }) async {
    print('AppStorePurchaseHandler.handleValidation');
    final response = await _iTunesAPI.verifyReceipt(
      password: appStoreSharedSecret,
      receiptData: token,
    );
    print('response: $response');
    if (response.status == 0) {
      print('Successfully verified purchase');
      final receipts = response.latestReceiptInfo ?? [];
      for (final receipt in receipts) {
        final product = productDataMap[receipt.productId];
        if (product == null) {
          print('Error: Unknown product: ${receipt.productId}');
          continue;
        }
        switch (product.type) {
          case ProductType.nonSubscription:
            await iapRepository.createOrUpdatePurchase(NonSubscriptionPurchase(
              userId: userId,
              productId: receipt.productId ?? '',
              iapSource: IAPSource.appstore,
              orderId: receipt.originalTransactionId ?? '',
              purchaseDate: DateTime.fromMillisecondsSinceEpoch(int.parse(receipt.originalPurchaseDateMs ?? '0')),
              type: product.type,
              status: NonSubscriptionStatus.completed,
            ));
            break;
          case ProductType.subscription:
            await iapRepository.createOrUpdatePurchase(SubscriptionPurchase(
              userId: userId,
              productId: receipt.productId ?? '',
              iapSource: IAPSource.appstore,
              orderId: receipt.originalTransactionId ?? '',
              purchaseDate: DateTime.fromMillisecondsSinceEpoch(int.parse(receipt.originalPurchaseDateMs ?? '0')),
              type: product.type,
              expiryDate: DateTime.fromMillisecondsSinceEpoch(int.parse(receipt.expiresDateMs ?? '0')),
              status: SubscriptionStatus.active,
            ));
            break;
        }
      }
      return true;
    } else {
      print('Error: Status: ${response.status}');
      return false;
    }
  }

  /// Request the App Store for the latest subscription status.
  /// Updates all App Store subscriptions in the database.
  /// NOTE: This code only handles when a subscription expires as example.
  Future<void> _pullStatus() async {
    print('Polling App Store');
    final purchases = await iapRepository.getPurchases();
    // filter for App Store subscriptions
    final appStoreSubscriptions = purchases.where((element) => element.type == ProductType.subscription && element.iapSource == IAPSource.appstore);
    for (final purchase in appStoreSubscriptions) {
      final status = await appStoreServerAPI.getAllSubscriptionStatuses(purchase.orderId);
      // Obtain all subscriptions for the order id.
      for (final subscription in status.data) {
        // Last transaction contains the subscription status.
        for (final transaction in subscription.lastTransactions) {
          final expirationDate = DateTime.fromMillisecondsSinceEpoch(transaction.transactionInfo.expiresDate ?? 0);
          // Check if subscription has expired.
          final isExpired = expirationDate.isBefore(DateTime.now());
          print('Expiration Date: $expirationDate - isExpired: $isExpired');
          // Update the subscription status with the new expiration date and status.
          await iapRepository.updatePurchase(SubscriptionPurchase(
            userId: null,
            productId: transaction.transactionInfo.productId,
            iapSource: IAPSource.appstore,
            orderId: transaction.originalTransactionId,
            purchaseDate: DateTime.fromMillisecondsSinceEpoch(transaction.transactionInfo.originalPurchaseDate),
            type: ProductType.subscription,
            expiryDate: expirationDate,
            status: isExpired ? SubscriptionStatus.expired : SubscriptionStatus.active,
          ));
        }
      }
    }
  }
}
