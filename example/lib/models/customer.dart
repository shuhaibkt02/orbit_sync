class Customer {
  final String id;
  final String name;
  final double creditLimit;
  final double outstandingBalance;
  final String tier;

  const Customer({
    required this.id,
    required this.name,
    required this.creditLimit,
    this.outstandingBalance = 0.0,
    this.tier = 'STANDARD',
  });

  bool canAffordOrder(double amount) =>
      (outstandingBalance + amount) <= creditLimit;

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        id: json['id'] as String,
        name: json['name'] as String,
        creditLimit: (json['credit_limit'] as num).toDouble(),
        outstandingBalance:
            (json['outstanding_balance'] as num?)?.toDouble() ?? 0.0,
        tier: json['tier'] as String? ?? 'STANDARD',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'credit_limit': creditLimit,
        'outstanding_balance': outstandingBalance,
        'tier': tier,
      };
}
